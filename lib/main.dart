import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
// kIsWebを使用するために必要
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

void main() {
  runApp(const FlightSimApp());
}

class FlightSimApp extends StatelessWidget {
  const FlightSimApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Flight Sim Base',
      theme: ThemeData(primarySwatch: Colors.blue, useMaterial3: true),
      home: const FlightSimulatorPage(),
    );
  }
}

class FlightSimulatorPage extends StatefulWidget {
  const FlightSimulatorPage({super.key});

  @override
  State<FlightSimulatorPage> createState() => _FlightSimulatorPageState();
}

class _FlightSimulatorPageState extends State<FlightSimulatorPage>
    with SingleTickerProviderStateMixin {
  MapLibreMapController? mapController;
  late Ticker _ticker;

  // ジョイスティックの状態管理
  Offset _moveInput = Offset.zero; // 左スティック (x:左右, y:前後)
  Offset _lookInput = Offset.zero; // 右スティック (x:回転, y:チルト)

  // 【修正】羽田空港 滑走路の座標
  static const LatLng _startLatLng = LatLng(35.548, 139.784);

  // 【修正】初期カメラ設定（ここが確実に反映されるようにします）
  static const CameraPosition _initialCameraPosition = CameraPosition(
    target: _startLatLng,
    zoom: 16.0, // より詳細に見えるよう少しズームアップ
    tilt: 60.0, // 3D感を出すための傾き
    bearing: 340.0, // 羽田の滑走路の向き
  );

  // 現在のカメラ位置を保持（滑らかな移動のため）
  CameraPosition _currentCameraPosition = _initialCameraPosition;

  // 画面表示用のNotifier
  final ValueNotifier<int> _speedNotifier = ValueNotifier(0);
  final ValueNotifier<int> _altitudeNotifier = ValueNotifier(
    500,
  ); // Zoom 16.0 相当の概算高度(m)
  // 【追加】ロール角（傾き）制御用のNotifier
  final ValueNotifier<double> _rollNotifier = ValueNotifier(0.0);
  // 【追加】ピッチ角（Tilt）制御用のNotifier (HUD用)
  final ValueNotifier<double> _pitchNotifier = ValueNotifier(60.0);
  // HUDの表示状態
  bool _isHudVisible = false;
  // 地図モード (0: 衛星, 1: 標準, 2: ハイブリッド)
  int _mapMode = 0;
  // ハイブリッドモード時の透明度
  double _overlayOpacity = 0.5;
  // GPSモード（ナビモード）の状態
  bool _isGpsMode = false;
  StreamSubscription<Position>? _gpsSubscription;

  @override
  void initState() {
    super.initState();
    // 毎フレーム呼び出されるTickerを作成
    _ticker = createTicker(_onTick);
    _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _speedNotifier.dispose();
    _altitudeNotifier.dispose();
    _rollNotifier.dispose();
    _pitchNotifier.dispose();
    _gpsSubscription?.cancel();
    super.dispose();
  }

  // 毎フレーム実行されるループ処理
  void _onTick(Duration elapsed) {
    if (mapController == null) return;

    // 入力の有無を確認
    bool hasInput = _moveInput != Offset.zero || _lookInput != Offset.zero;

    // GPSモード中にジョイスティック操作があれば解除
    if (_isGpsMode && hasInput) {
      _disableGpsMode();
    }

    // GPSモード中はフライトシミュレーション（移動計算）を行わない
    if (_isGpsMode) return;

    // --- ロール（Roll）の計算 ---
    // 旋回入力 (_lookInput.dx) に応じて機体を傾ける (最大20度)
    double targetRoll = _lookInput.dx * (20.0 * math.pi / 180.0);
    double currentRoll = _rollNotifier.value;
    // 滑らかに変化させる (Lerp)
    double newRoll = currentRoll + (targetRoll - currentRoll) * 0.1;

    // ロール更新が必要か判定（微小な値の変化も反映させて水平に戻すため）
    bool isRolling =
        (targetRoll - currentRoll).abs() > 0.001 || currentRoll.abs() > 0.001;

    if (isRolling) {
      _rollNotifier.value = newRoll;
    }

    // 入力がなく、ロールも水平に戻っていれば処理をスキップ
    if (!hasInput && !isRolling) {
      return;
    }

    // --- 1. 視点（Look）の計算 ---
    // Bearing (左右回転)
    double newBearing = _currentCameraPosition.bearing + _lookInput.dx * 2.0;

    // Tilt (ピッチ):
    // 前に倒す(dy < 0) -> tiltを減らす(垂直に近づく)
    // 後ろに倒す(dy > 0) -> tiltを増やす(水平に近づく)
    // 感度調整のため 1.5倍にしています
    double tiltDelta = _lookInput.dy * 1.5;
    // MapLibreの仕様上、ピッチの上限は60度です。
    double newTilt = (_currentCameraPosition.tilt + tiltDelta).clamp(0.0, 60.0);

    // HUD用にピッチを通知
    _pitchNotifier.value = newTilt;

    // --- 2. 移動（Move）の計算 ---
    double bearingRad = newBearing * (math.pi / 180.0);
    const double speed = 0.00005;

    double forwardAmount = -_moveInput.dy * speed;
    double strafeAmount = _moveInput.dx * speed;

    double dLat = math.cos(bearingRad) * forwardAmount;
    double dLng = math.sin(bearingRad) * forwardAmount;

    double strafeRad = bearingRad + (math.pi / 2.0);
    dLat += math.cos(strafeRad) * strafeAmount;
    dLng += math.sin(strafeRad) * strafeAmount;

    double newLat = _currentCameraPosition.target.latitude + dLat;
    double newLng = _currentCameraPosition.target.longitude + dLng;

    // --- 高度（Zoom）の計算 (移動連動) ---
    // 前進時、現在のピッチ角(Tilt)に応じて高度を変更します。
    // 基準Tilt(45度)より大きい(60度に近い)場合は上昇、小さい場合は下降とみなします。
    // 上昇 -> Zoom Out (値を減らす)
    double pitchFactor = (newTilt - 45.0); // 例: 60度なら+15(上昇), 30度なら-15(下降)
    // 係数調整: forwardAmount * pitchFactor * 感度
    double zoomChange = forwardAmount * pitchFactor * 3.0;
    double newZoom = (_currentCameraPosition.zoom - zoomChange).clamp(
      10.0,
      20.0,
    );

    // 高度表示の更新 (Zoom 16.0 = 500m と仮定)
    int currentAltitude = (500 * math.pow(2, 16.0 - newZoom)).toInt();
    if (_altitudeNotifier.value != currentAltitude) {
      _altitudeNotifier.value = currentAltitude;
    }

    // --- 3. カメラ更新 (Web版のバグ回避用) ---
    _currentCameraPosition = CameraPosition(
      target: LatLng(newLat, newLng),
      bearing: newBearing.toDouble(),
      tilt: newTilt.toDouble(),
      zoom: newZoom,
    );

    // JSバージョンを固定したため、moveCamera (jumpTo) で正常にピッチが反映されるはずです。
    // animateCameraを毎フレーム呼ぶと動作が不安定になるため、moveCameraを使用します。
    mapController?.moveCamera(
      CameraUpdate.newCameraPosition(_currentCameraPosition),
    );

    // 速度表示の更新 (簡易計算: 0.00005 deg/tick * 60fps * 111km/deg ≈ 1200km/h)
    double currentSpeedKmh = _moveInput.distance * 1200.0;
    if (_speedNotifier.value != currentSpeedKmh.toInt()) {
      _speedNotifier.value = currentSpeedKmh.toInt();
    }
  }

  // スタイルJSONの生成
  // ArcGIS Satellite (Raster) + OSM Buildings (Vector)
  // 注意: 3D建物を表示するには、有効なVector TileのURL（例: MapTiler）が必要です。
  String _buildStyleJson() {
    // OpenFreeMapで表示されない問題が発生したため、確実に動作するMapTilerに戻します。
    // 以前のAPIキーを使用します。
    const String apiKey = 'JKnzrvTJYzZYRMufAObp';

    // 共通のソース（地形）
    final Map<String, dynamic> sources = {
      "terrain-source": {
        "type": "raster-dem",
        "url":
            "https://api.maptiler.com/tiles/terrain-rgb/tiles.json?key=$apiKey",
        "tileSize": 256,
      },
      "satellite-source": {
        "type": "raster",
        "tiles": [
          "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}",
        ],
        "tileSize": 256,
        "attribution":
            "Esri, Maxar, Earthstar Geographics, and the GIS User Community",
      },
      "osm-source": {
        "type": "raster",
        "tiles": ["https://tile.openstreetmap.org/{z}/{x}/{y}.png"],
        "tileSize": 256,
        "attribution": "© OpenStreetMap contributors",
      },
    };

    List<Map<String, dynamic>> layers = [
      // 背景レイヤー
      {
        "id": "background",
        "type": "background",
        "paint": {"background-color": "#000000"},
      },
    ];

    if (_mapMode == 0 || _mapMode == 2) {
      layers.add({
        "id": "satellite-layer",
        "type": "raster",
        "source": "satellite-source",
        "paint": {"raster-opacity": 1.0},
      });
    }

    if (_mapMode == 1 || _mapMode == 2) {
      layers.add({
        "id": "osm-layer",
        "type": "raster",
        "source": "osm-source",
        "paint": {
          "raster-opacity": _mapMode == 2 ? _overlayOpacity : 1.0,
        }, // ハイブリッド時は変数を使用
      });
    }

    return jsonEncode({
      "version": 8,
      // フォントデータを取得するためのURLテンプレートを追加（これがないとテキスト関連のエラーでクラッシュします）
      "glyphs":
          "https://api.maptiler.com/fonts/{fontstack}/{range}.pbf?key=$apiKey",
      "sources": sources,
      // 地形表示を有効化
      "terrain": {
        "source": "terrain-source",
        "exaggeration": 1.5, // 起伏を少し強調して表示
      },
      "layers": layers,
    });
  }

  // GPSモードを有効化（現在地に追従）
  Future<void> _enableGpsMode() async {
    bool serviceEnabled;
    LocationPermission permission;

    // 1. 位置情報サービスが有効か確認
    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      debugPrint('Location services are disabled.');
      return;
    }

    // 2. 権限の確認とリクエスト
    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        debugPrint('Location permissions are denied');
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      debugPrint('Location permissions are permanently denied.');
      return;
    }

    setState(() {
      _isGpsMode = true;
      _rollNotifier.value = 0.0; // ロールをリセット
    });

    // 既存のサブスクリプションがあればキャンセル
    await _gpsSubscription?.cancel();

    // 位置情報のストリームを購読
    _gpsSubscription =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 5, // 5mごとの更新
          ),
        ).listen((Position position) {
          if (!mounted || mapController == null) return;

          // 現在のズームやチルトは維持しつつ、位置だけ更新
          _currentCameraPosition = CameraPosition(
            target: LatLng(position.latitude, position.longitude),
            zoom: _currentCameraPosition.zoom,
            tilt: _currentCameraPosition.tilt,
            bearing: _currentCameraPosition.bearing,
          );

          mapController!.moveCamera(
            CameraUpdate.newCameraPosition(_currentCameraPosition),
          );
        });
  }

  // GPSモードを解除
  void _disableGpsMode() {
    if (_isGpsMode) {
      setState(() {
        _isGpsMode = false;
      });
      _gpsSubscription?.cancel();
      _gpsSubscription = null;
    }
  }

  void _onMapCreated(MapLibreMapController controller) {
    mapController = controller;
    // まずは初期設定（羽田）へ移動しておく
    controller.moveCamera(
      CameraUpdate.newCameraPosition(_initialCameraPosition),
    );
    // その後、現在地取得を試みる
    _enableGpsMode();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // 1. Map Layer
          // ロール演出のためにTransformでラップして回転させる
          ValueListenableBuilder<double>(
            valueListenable: _rollNotifier,
            builder: (context, roll, child) {
              return Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()
                  ..scale(1.2) // 回転時に四隅が切れないように少し拡大
                  ..rotateZ(roll),
                child: child,
              );
            },
            // 地図へのタッチ操作（手動移動）を検出してGPSモードを解除
            child: Listener(
              onPointerDown: (_) => _disableGpsMode(),
              child: MapLibreMap(
                onMapCreated: _onMapCreated,
                initialCameraPosition: _initialCameraPosition,
                // カメラが動いたときに現在位置変数を更新する
                onCameraMove: (position) {
                  // ジョイスティック操作中は、自前の計算値を優先するため更新しない
                  if (_moveInput == Offset.zero && _lookInput == Offset.zero) {
                    _currentCameraPosition = position;
                  }
                },
                styleString: _buildStyleJson(),
                tiltGesturesEnabled: true, // 手動での傾けを許可
                rotateGesturesEnabled: true, // 回転を許可（ピッチ変更に影響する可能性があるため明示的に有効化）
                zoomGesturesEnabled: true, // ズームを許可
                onStyleLoadedCallback: () {
                  // スタイル読み込み完了後に現在位置（ピッチ含む）を適用
                  mapController?.moveCamera(
                    CameraUpdate.newCameraPosition(_currentCameraPosition),
                  );
                },
                // 【修正】Web版でのズーム起点ズレやパフォーマンス低下を防ぐため false に設定
                trackCameraPosition: false,
                // 以下の2行を追加してWebの制限を緩和します
                minMaxZoomPreference: const MinMaxZoomPreference(0, 20),
                myLocationEnabled: false,
              ),
            ),
          ),

          // 3. HUD Layer (Pitch Ladder) - Mapと同じく回転させる
          if (_isHudVisible)
            IgnorePointer(
              child: ValueListenableBuilder<double>(
                valueListenable: _rollNotifier,
                builder: (context, roll, child) {
                  return Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()..rotateZ(roll),
                    child: child,
                  );
                },
                child: ValueListenableBuilder<double>(
                  valueListenable: _pitchNotifier,
                  builder: (context, pitch, child) {
                    return CustomPaint(
                      painter: HudPitchLadderPainter(tilt: pitch),
                      child: Container(),
                    );
                  },
                ),
              ),
            ),

          // 4. HUD Layer (Static) - 固定表示 (Boresight)
          if (_isHudVisible)
            const IgnorePointer(
              child: CustomPaint(
                painter: HudStaticPainter(),
                child: SizedBox.expand(),
              ),
            ),

          // 2. UI Layer (Joysticks)
          // 左下のジョイスティック (移動用などを想定)
          Positioned(
            left: 40,
            bottom: 40,
            child: _buildJoystick(
              label: "Move",
              onChanged: (val) => _moveInput = val,
            ),
          ),

          // 右下のジョイスティック (視点操作用などを想定)
          Positioned(
            right: 40,
            bottom: 40,
            child: _buildJoystick(
              label: "Look",
              onChanged: (val) => _lookInput = val,
            ),
          ),

          // タイトル表示（デバッグ用）
          const Positioned(
            top: 50,
            left: 20,
            child: Text(
              "Flight Simulator Base",
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
                shadows: [Shadow(blurRadius: 4, color: Colors.black)],
              ),
            ),
          ),

          // 高度・速度情報の表示
          Positioned(
            top: 80,
            left: 20,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildInfoRow("Altitude", _altitudeNotifier, "m"),
                _buildInfoRow("Speed", _speedNotifier, "km/h"),
              ],
            ),
          ),

          // GPSモードボタン（現在地追従）
          Positioned(
            top: 50,
            right: 20,
            child: FloatingActionButton(
              mini: true,
              backgroundColor: Colors.white.withOpacity(0.8),
              onPressed: _enableGpsMode,
              child: Icon(
                Icons.my_location,
                color: _isGpsMode ? Colors.blue : Colors.black,
              ),
            ),
          ),

          // HUD On/Offボタン
          Positioned(
            top: 110,
            right: 20,
            child: FloatingActionButton(
              mini: true,
              backgroundColor: Colors.white.withOpacity(0.8),
              onPressed: () {
                setState(() {
                  _isHudVisible = !_isHudVisible;
                });
              },
              child: Icon(
                _isHudVisible ? Icons.visibility : Icons.visibility_off,
                color: Colors.black,
              ),
            ),
          ),

          // 地図モード切替ボタン
          Positioned(
            top: 170,
            right: 20,
            child: FloatingActionButton(
              mini: true,
              backgroundColor: Colors.white.withOpacity(0.8),
              onPressed: () {
                setState(() {
                  _mapMode = (_mapMode + 1) % 3;
                });
              },
              child: Icon(
                _mapMode == 0
                    ? Icons.satellite
                    : (_mapMode == 1 ? Icons.map : Icons.layers),
                color: Colors.black,
              ),
            ),
          ),

          // ハイブリッドモード用 透明度スライダー
          if (_mapMode == 2)
            Positioned(
              top: 230,
              right: 10,
              child: RotatedBox(
                quarterTurns: 3, // 縦向きにする
                child: Container(
                  width: 150,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Slider(
                    value: _overlayOpacity,
                    min: 0.0,
                    max: 1.0,
                    activeColor: Colors.white,
                    inactiveColor: Colors.white.withOpacity(0.3),
                    onChanged: (value) {
                      setState(() {
                        _overlayOpacity = value;
                      });
                    },
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // 情報表示用の行ウィジェット
  Widget _buildInfoRow(String label, ValueNotifier<int> notifier, String unit) {
    return ValueListenableBuilder<int>(
      valueListenable: notifier,
      builder: (context, value, child) {
        return Text(
          "$label: $value $unit",
          style: const TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.bold,
            shadows: [Shadow(blurRadius: 4, color: Colors.black)],
          ),
        );
      },
    );
  }

  // 透過した丸いジョイスティックのUIパーツ
  Widget _buildJoystick({
    required String label,
    required ValueChanged<Offset> onChanged,
  }) {
    // 内部でAlignment状態を持つためにStatefulWidgetにするのが理想ですが、
    // 簡易的にTweenAnimationBuilderやStatefulBuilderを使うか、
    // ここでは親のsetStateに頼らず、GestureDetectorの更新で変数を変えつつ
    // UI更新用にValueNotifierなどを使うのが軽量です。
    // 今回はコードの単純化のため、StatefulWidgetとして定義し直す代わりに
    // StatefulBuilderを使ってローカルな再描画を行います。

    // 現在のスティック位置 (Alignment: -1.0 ~ 1.0)
    // StatefulBuilderの外で定義して、再描画時も状態が保持されるようにする
    Alignment stickAlign = Alignment.center;

    return StatefulBuilder(
      builder: (context, setState) {
        // 直近の入力値から計算（親の変数を参照する形だと再描画サイクルとずれる可能性があるため、ローカル変数で管理）
        // ただし今回はシンプルに、ドラッグイベント内でsetStateしてAlignmentを更新します。

        return GestureDetector(
          onPanStart: (details) {},
          onPanUpdate: (details) {
            // コンテナの中心(60,60)からのオフセットを計算
            final dx = details.localPosition.dx - 60;
            final dy = details.localPosition.dy - 60;

            // 距離と角度
            final dist = math.sqrt(dx * dx + dy * dy);
            final angle = math.atan2(dy, dx);

            // 半径50.0以内に制限
            final cappedDist = math.min(dist, 50.0);
            final cappedDx = math.cos(angle) * cappedDist;
            final cappedDy = math.sin(angle) * cappedDist;

            // 正規化された入力値 (-1.0 ~ 1.0)
            final inputX = cappedDx / 50.0;
            final inputY = cappedDy / 50.0;

            onChanged(Offset(inputX, inputY));

            setState(() {
              stickAlign = Alignment(inputX, inputY);
            });
          },
          onPanEnd: (details) {
            // 指を離したらリセット
            onChanged(Offset.zero);
            setState(() {
              stickAlign = Alignment.center;
            });
          },
          child: Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.2), // 半透明の背景
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withOpacity(0.5),
                width: 2,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.2),
                  blurRadius: 10,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Stack(
              alignment: stickAlign, // スティックの位置を更新
              children: [
                // 中央のスティック部分
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.4),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.1),
                        blurRadius: 5,
                      ),
                    ],
                  ),
                ),
                // ラベル
                Positioned(
                  bottom: 15,
                  child: Text(
                    label,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.8),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// HUD: ピッチラダー（水平線と角度線）を描画するPainter
class HudPitchLadderPainter extends CustomPainter {
  final double tilt;

  HudPitchLadderPainter({required this.tilt});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final paint = Paint()
      ..color = const Color(0xFF00FF00)
          .withOpacity(0.8) // HUD Green
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    // 画面上のピクセル/度 (調整可能)
    const double pxPerDeg = 15.0;

    // 基準となるTilt(45度)からの差分で、水平線の位置を決定
    // Tiltが増える(60度に近い) = 上を向く = 水平線は下に下がる
    double horizonOffset = (tilt - 45.0) * pxPerDeg;

    // 水平線 (Horizon)
    final horizonY = center.dy + horizonOffset;
    canvas.drawLine(
      Offset(center.dx - 150, horizonY),
      Offset(center.dx + 150, horizonY),
      paint,
    );

    // ピッチラインを描画 (+10, +20, -10, -20...)
    // 45度を0度(水平)とし、そこからの相対角度で線を描く
    for (int i = -30; i <= 30; i += 10) {
      if (i == 0) continue; // 0は水平線として描画済み

      // i度のラインの位置
      // ピッチがプラス(上)の線は、水平線より上にあるべき
      // 画面座標系では上がマイナス
      double lineY = horizonY - (i * pxPerDeg);

      // 画面外なら描画しない(簡易クリッピング)
      if (lineY < 0 || lineY > size.height) continue;

      double lineWidth = (i % 20 == 0) ? 80.0 : 40.0;

      // 左側
      canvas.drawLine(
        Offset(center.dx - 20 - lineWidth, lineY),
        Offset(center.dx - 20, lineY),
        paint,
      );
      // 右側
      canvas.drawLine(
        Offset(center.dx + 20, lineY),
        Offset(center.dx + 20 + lineWidth, lineY),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant HudPitchLadderPainter oldDelegate) {
    return oldDelegate.tilt != tilt;
  }
}

// HUD: 固定表示（ボアサイトなど）を描画するPainter
class HudStaticPainter extends CustomPainter {
  const HudStaticPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final paint = Paint()
      ..color = const Color(0xFF00FF00).withOpacity(0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    // ボアサイト (Wマークのようなもの) - 画面中央に固定
    const double w = 20.0;
    const double h = 10.0;

    final path = Path()
      ..moveTo(center.dx - w, center.dy - h)
      ..lineTo(center.dx - w / 2, center.dy)
      ..lineTo(center.dx, center.dy - h / 2)
      ..lineTo(center.dx + w / 2, center.dy)
      ..lineTo(center.dx + w, center.dy - h);

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
