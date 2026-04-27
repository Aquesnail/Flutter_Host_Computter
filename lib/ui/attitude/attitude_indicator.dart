import 'dart:math';
import 'package:flutter/material.dart';
import 'package:vector_math/vector_math.dart';

class Attitude {
  final double roll;
  final double pitch;
  final double yaw;

  const Attitude(this.roll, this.pitch, this.yaw);
  const Attitude.zero() : this(0, 0, 0);

  Attitude copyWith({double? roll, double? pitch, double? yaw}) {
    return Attitude(roll ?? this.roll, pitch ?? this.pitch, yaw ?? this.yaw);
  }

  @override
  bool operator ==(Object other) =>
      other is Attitude &&
      other.roll == roll &&
      other.pitch == pitch &&
      other.yaw == yaw;

  @override
  int get hashCode => Object.hash(roll, pitch, yaw);
}

class _Model3D {
  final List<Vector3> vertices;
  final List<(int, int)> edges;
  final List<(int, int, int)> faces;

  _Model3D(this.vertices, this.edges, this.faces);
}

_Model3D _buildDrone() {
  final v = <Vector3>[];
  final e = <(int, int)>[];
  final f = <(int, int, int)>[];

  void line(Vector3 a, Vector3 b) {
    final i = v.length;
    v.addAll([a, b]);
    e.add((i, i + 1));
  }

  void box(Vector3 c, double wx, double wy, double wz) {
    final base = v.length;
    final x = wx / 2, y = wy / 2, z = wz / 2;
    v.addAll([
      Vector3(c.x - x, c.y - y, c.z - z),
      Vector3(c.x + x, c.y - y, c.z - z),
      Vector3(c.x + x, c.y + y, c.z - z),
      Vector3(c.x - x, c.y + y, c.z - z),
      Vector3(c.x - x, c.y - y, c.z + z),
      Vector3(c.x + x, c.y - y, c.z + z),
      Vector3(c.x + x, c.y + y, c.z + z),
      Vector3(c.x - x, c.y + y, c.z + z),
    ]);
    const segs = [
      (0, 1), (1, 2), (2, 3), (3, 0), // bottom
      (4, 5), (5, 6), (6, 7), (7, 4), // top
      (0, 4), (1, 5), (2, 6), (3, 7), // sides
    ];
    for (final (a, b) in segs) {
      e.add((base + a, base + b));
    }
    // Faces (CCW from outside)
    const tris = [
      (0, 3, 2), (0, 2, 1), // bottom
      (4, 5, 6), (4, 6, 7), // top
      (3, 2, 6), (3, 6, 7), // front
      (0, 4, 5), (0, 5, 1), // back
      (1, 2, 6), (1, 6, 5), // right
      (0, 3, 7), (0, 7, 4), // left
    ];
    for (final (a, b, c) in tris) {
      f.add((base + a, base + b, base + c));
    }
  }

  // Center body
  box(Vector3.zero(), 28, 18, 10);

  // Motors
  const arm = 48.0;
  final motors = [
    Vector3(arm, arm, 0),
    Vector3(-arm, arm, 0),
    Vector3(arm, -arm, 0),
    Vector3(-arm, -arm, 0),
  ];

  for (final m in motors) {
    box(m, 12, 12, 6);
    // Propeller cross
    line(m + Vector3(14, 0, 0), m + Vector3(-14, 0, 0));
    line(m + Vector3(0, 14, 0), m + Vector3(0, -14, 0));
  }

  // Arms
  line(Vector3(14, 9, 0), motors[0]);
  line(Vector3(-14, 9, 0), motors[1]);
  line(Vector3(14, -9, 0), motors[2]);
  line(Vector3(-14, -9, 0), motors[3]);

  // Direction indicator (nose)
  line(Vector3(0, 20, 0), Vector3(0, 32, 0));
  line(Vector3(-4, 28, 0), Vector3(0, 32, 0));
  line(Vector3(4, 28, 0), Vector3(0, 32, 0));

  return _Model3D(v, e, f);
}

_Model3D _buildCar() {
  final v = <Vector3>[];
  final e = <(int, int)>[];
  final f = <(int, int, int)>[];

  void line(Vector3 a, Vector3 b) {
    final i = v.length;
    v.addAll([a, b]);
    e.add((i, i + 1));
  }

  void box(Vector3 c, double wx, double wy, double wz) {
    final base = v.length;
    final x = wx / 2, y = wy / 2, z = wz / 2;
    v.addAll([
      Vector3(c.x - x, c.y - y, c.z - z),
      Vector3(c.x + x, c.y - y, c.z - z),
      Vector3(c.x + x, c.y + y, c.z - z),
      Vector3(c.x - x, c.y + y, c.z - z),
      Vector3(c.x - x, c.y - y, c.z + z),
      Vector3(c.x + x, c.y - y, c.z + z),
      Vector3(c.x + x, c.y + y, c.z + z),
      Vector3(c.x - x, c.y + y, c.z + z),
    ]);
    const segs = [
      (0, 1), (1, 2), (2, 3), (3, 0),
      (4, 5), (5, 6), (6, 7), (7, 4),
      (0, 4), (1, 5), (2, 6), (3, 7),
    ];
    for (final (a, b) in segs) {
      e.add((base + a, base + b));
    }
    const tris = [
      (0, 3, 2), (0, 2, 1), // bottom
      (4, 5, 6), (4, 6, 7), // top
      (3, 2, 6), (3, 6, 7), // front
      (0, 4, 5), (0, 5, 1), // back
      (1, 2, 6), (1, 6, 5), // right
      (0, 3, 7), (0, 7, 4), // left
    ];
    for (final (a, b, c) in tris) {
      f.add((base + a, base + b, base + c));
    }
  }

  // Chassis
  box(Vector3(0, 0, 18), 76, 48, 12);

  // Wheels (simplified as standing boxes)
  const wx = 40.0;
  const wy = 26.0;
  const wz = 8.0;
  const wr = 10.0; // wheel radius-ish

  for (final sx in [-1.0, 1.0]) {
    for (final sy in [-1.0, 1.0]) {
      final c = Vector3(sx * wx, sy * wy, wz);
      // Wheel is a thin box
      box(c, 6, 4, wr * 2);
      // Axle line
      line(Vector3(sx * 32, sy * wy, wz), c);
    }
  }

  // Direction indicator (front)
  line(Vector3(0, 30, 18), Vector3(0, 40, 18));
  line(Vector3(-5, 36, 18), Vector3(0, 40, 18));
  line(Vector3(5, 36, 18), Vector3(0, 40, 18));

  return _Model3D(v, e, f);
}

Vector3 _rotate(Vector3 v, double roll, double pitch, double yaw) {
  double x = v.x, y = v.y, z = v.z;

  // Pitch around X
  final cp = cos(pitch), sp = sin(pitch);
  final y1 = y * cp - z * sp;
  final z1 = y * sp + z * cp;

  // Roll around Y
  final cr = cos(roll), sr = sin(roll);
  final x2 = x * cr + z1 * sr;
  final z2 = -x * sr + z1 * cr;

  // Yaw around Z
  final cy = cos(yaw), sy = sin(yaw);
  final x3 = x2 * cy - y1 * sy;
  final y3 = x2 * sy + y1 * cy;

  return Vector3(x3, y3, z2);
}

Vector3 _cameraRotate(Vector3 v, double pitch, double yaw) {
  double x = v.x, y = v.y, z = v.z;

  // Yaw (Y axis)
  final cy = cos(yaw), sy = sin(yaw);
  final x1 = x * cy + z * sy;
  final z1 = -x * sy + z * cy;

  // Pitch (X axis)
  final cp = cos(pitch), sp = sin(pitch);
  final y2 = y * cp - z1 * sp;
  final z2 = y * sp + z1 * cp;

  return Vector3(x1, y2, z2);
}

Offset _project(Vector3 v, Size size, double scale) {
  const dist = 300.0;
  final s = dist / (dist + v.y);
  final x = v.x * s * scale + size.width / 2;
  final y = -v.z * s * scale + size.height / 2;
  return Offset(x, y);
}

class _FaceInfo {
  final (int, int, int) indices;
  final double depth;
  final double brightness;
  final Path path;

  _FaceInfo(this.indices, this.depth, this.brightness, this.path);
}

class AttitudePainter extends CustomPainter {
  final Attitude attitude;
  final bool isDrone;
  final Color color;
  final bool solidMode;
  final double cameraPitch;
  final double cameraYaw;

  AttitudePainter({
    required this.attitude,
    required this.isDrone,
    required this.color,
    this.solidMode = false,
    this.cameraPitch = -0.45,
    this.cameraYaw = -0.55,
  }) : super(repaint: null);

  static final _droneModel = _buildDrone();
  static final _carModel = _buildCar();

  @override
  void paint(Canvas canvas, Size size) {
    final model = isDrone ? _droneModel : _carModel;
    final scale = min(size.width, size.height) / 220;

    final groundPaint = Paint()
      ..color = color.withValues(alpha: 0.12)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    // Draw ground reference grid (horizontal plane)
    const gridStep = 30.0;
    const gridRange = 90.0;
    for (double gx = -gridRange; gx <= gridRange; gx += gridStep) {
      final a = _project(_cameraRotate(Vector3(gx, -gridRange, 0), cameraPitch, cameraYaw), size, scale);
      final b = _project(_cameraRotate(Vector3(gx, gridRange, 0), cameraPitch, cameraYaw), size, scale);
      canvas.drawLine(a, b, groundPaint);
    }
    for (double gy = -gridRange; gy <= gridRange; gy += gridStep) {
      final a = _project(_cameraRotate(Vector3(-gridRange, gy, 0), cameraPitch, cameraYaw), size, scale);
      final b = _project(_cameraRotate(Vector3(gridRange, gy, 0), cameraPitch, cameraYaw), size, scale);
      canvas.drawLine(a, b, groundPaint);
    }

    // Transform vertices: model rotate -> camera rotate -> project
    final projected = List<Offset>.filled(model.vertices.length, Offset.zero);
    final cameraVerts = List<Vector3>.filled(model.vertices.length, Vector3.zero());

    for (var i = 0; i < model.vertices.length; i++) {
      final r = _rotate(model.vertices[i], attitude.roll, attitude.pitch, attitude.yaw);
      final cam = _cameraRotate(r, cameraPitch, cameraYaw);
      cameraVerts[i] = cam;
      projected[i] = _project(cam, size, scale);
    }

    // Draw faces (solid mode)
    if (solidMode && model.faces.isNotEmpty) {
      final faces = <_FaceInfo>[];
      final lightDir = Vector3(0.0, -1.0, 0.5); // from front-top

      for (final (a, b, c) in model.faces) {
        final p0 = projected[a];
        final p1 = projected[b];
        final p2 = projected[c];

        // Back-face culling (screen space CCW check)
        final crossZ = (p1.dx - p0.dx) * (p2.dy - p0.dy) - (p1.dy - p0.dy) * (p2.dx - p0.dx);
        if (crossZ <= 0) continue;

        // Depth sorting (average camera-space Y, which is depth)
        final depth = cameraVerts[a].y + cameraVerts[b].y + cameraVerts[c].y;

        // Simple lighting in camera space
        final ab = cameraVerts[b] - cameraVerts[a];
        final ac = cameraVerts[c] - cameraVerts[a];
        final normal = ab.cross(ac)..normalize();
        var brightness = -normal.dot(lightDir);
        brightness = (brightness * 0.6 + 0.4).clamp(0.15, 1.0);

        final path = Path()
          ..moveTo(p0.dx, p0.dy)
          ..lineTo(p1.dx, p1.dy)
          ..lineTo(p2.dx, p2.dy)
          ..close();

        faces.add(_FaceInfo((a, b, c), depth, brightness, path));
      }

      // Painter's algorithm: far to near (larger Y is farther away in camera space)
      faces.sort((a, b) => b.depth.compareTo(a.depth));

      for (final face in faces) {
        final faceColor = Color.fromARGB(
          255,
          (color.r * face.brightness).toInt().clamp(0, 255),
          (color.g * face.brightness).toInt().clamp(0, 255),
          (color.b * face.brightness).toInt().clamp(0, 255),
        );
        canvas.drawPath(
          face.path,
          Paint()
            ..color = faceColor
            ..style = PaintingStyle.fill,
        );
      }
    }

    // Draw edges (always on top in solid mode)
    final edgePaint = Paint()
      ..color = solidMode ? color.withValues(alpha: 0.9) : color
      ..strokeWidth = solidMode ? 1.0 : 1.5
      ..style = PaintingStyle.stroke;

    for (final (a, b) in model.edges) {
      canvas.drawLine(projected[a], projected[b], edgePaint);
    }
  }

  @override
  bool shouldRepaint(covariant AttitudePainter old) {
    return old.attitude != attitude ||
        old.isDrone != isDrone ||
        old.color != color ||
        old.solidMode != solidMode ||
        old.cameraPitch != cameraPitch ||
        old.cameraYaw != cameraYaw;
  }
}
