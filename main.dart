import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

// =====================================================================
//  MODELOS: opción de un selector, canal, modo, perfil (tipo de equipo)
//  y equipo instalado (con su dirección DMX).
// =====================================================================

class Opt {
  String label;
  int from;
  int to;
  Opt(String label, int from, [int? to])
      : label = label,
        from = from,
        to = to ?? from;
  Map<String, dynamic> toJson() => {'l': label, 'f': from, 't': to};
  factory Opt.fromJson(Map<String, dynamic> j) =>
      Opt(j['l'] as String, j['f'] as int, j['t'] as int);
}

class Preset {
  String name;
  Map<int, int> vals; // posición del canal dentro del modo -> valor
  Preset(this.name, this.vals);
  Map<String, dynamic> toJson() => {
        'n': name,
        'v': {for (final e in vals.entries) '${e.key}': e.value},
      };
  factory Preset.fromJson(Map<String, dynamic> j) => Preset(
        j['n'] as String,
        (j['v'] as Map).map((k, v) => MapEntry(int.parse(k as String), v as int)),
      );
}

class Chan {
  String name;
  int off; // posición dentro del modo, desde 1
  List<Opt> opts; // si tiene opciones, es un selector; si no, un fader
  int def;
  int min;
  int max;
  String key; // clave JSON opcional (ej. dimmerTA); si está vacía se usa el canal DMX
  Chan(String name,
      {int off = 0, List<Opt>? opts, int def = 0, int min = 0, int max = 255, String key = ''})
      : key = key,
        name = name,
        off = off,
        opts = opts ?? [],
        def = def,
        min = min,
        max = max;
  bool get isSelect => opts.isNotEmpty;
  Map<String, dynamic> toJson() => {
        'n': name,
        'o': off,
        'op': opts.map((o) => o.toJson()).toList(),
        'd': def,
        'mi': min,
        'ma': max,
        'k': key,
      };
  factory Chan.fromJson(Map<String, dynamic> j) => Chan(
        j['n'] as String,
        off: j['o'] as int,
        opts: (j['op'] as List)
            .map((e) => Opt.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        def: j['d'] as int,
        min: j['mi'] as int,
        max: j['ma'] as int,
        key: (j['k'] ?? '') as String,
      );
}

class Mode {
  String name;
  List<Chan> chans;
  List<Preset> presets;
  Mode(this.name, this.chans, {List<Preset>? presets})
      : presets = presets ?? [] {
    renumber();
  }
  void renumber() {
    for (var i = 0; i < chans.length; i++) {
      chans[i].off = i + 1;
    }
  }

  Map<String, dynamic> toJson() => {
        'n': name,
        'c': chans.map((c) => c.toJson()).toList(),
        'p': presets.map((p) => p.toJson()).toList(),
      };
  factory Mode.fromJson(Map<String, dynamic> j) => Mode(
        j['n'] as String,
        (j['c'] as List)
            .map((e) => Chan.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        presets: ((j['p'] ?? []) as List)
            .map((e) => Preset.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
      );
}

class Profile {
  String id;
  String name;
  String category;
  List<Mode> modes;
  bool builtIn;
  String panel; // 'rgb' = pantalla especial de color (tachos)
  String suffix; // sufijo de las claves del controlador (TA, TB...)
  Profile(this.id, this.name, this.category, this.modes,
      {this.builtIn = false, this.panel = '', this.suffix = ''});
  Map<String, dynamic> toJson() => {
        'id': id,
        'n': name,
        'cat': category,
        'm': modes.map((m) => m.toJson()).toList(),
        'pn': panel,
        'sf': suffix,
      };
  factory Profile.fromJson(Map<String, dynamic> j) => Profile(
        j['id'] as String,
        j['n'] as String,
        j['cat'] as String,
        (j['m'] as List)
            .map((e) => Mode.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        panel: (j['pn'] ?? '') as String,
        suffix: (j['sf'] ?? '') as String,
      );
  Profile copy() => Profile.fromJson(
      Map<String, dynamic>.from(jsonDecode(jsonEncode(toJson())) as Map));
}

class Fixture {
  String id;
  String name;
  String profileId;
  int mode;
  int address;
  List<Preset> mine; // escenas guardadas por el usuario
  Fixture(this.id, this.name, this.profileId, this.mode, this.address,
      {List<Preset>? mine})
      : mine = mine ?? [];
  Map<String, dynamic> toJson() => {
        'id': id,
        'n': name,
        'p': profileId,
        'm': mode,
        'a': address,
        'pr': mine.map((p) => p.toJson()).toList(),
      };
  factory Fixture.fromJson(Map<String, dynamic> j) => Fixture(
        j['id'] as String,
        j['n'] as String,
        j['p'] as String,
        j['m'] as int,
        j['a'] as int,
        mine: ((j['pr'] ?? []) as List)
            .map((e) => Preset.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
      );
}

// =====================================================================
//  PERFILES INCLUIDOS (sacados de los manuales)
//  Para equipos nuevos (tachos, spider, láser...) se usa el editor.
// =====================================================================

Chan _f(String n, {int min = 0, int max = 255, int def = 0}) =>
    Chan(n, min: min, max: max, def: def);
Chan _s(String n, List<Opt> o) => Chan(n, opts: o, def: o.first.from);

List<Opt> _strobe() => [
      Opt('Cerrado', 0, 5),
      Opt('Abierto', 6, 20),
      Opt('Sync lento→rápido', 21, 100),
      Opt('Pulso lento→rápido', 101, 150),
      Opt('Aleatorio lento→rápido', 151, 230),
      Opt('Abierto (2)', 231, 255),
    ];
List<Opt> _prisma() => [
      Opt('Prisma fuera', 0, 127),
      Opt('Prisma dentro', 128, 156),
      Opt('Rotación lento→rápido', 157, 255),
    ];
List<Opt> _frost() => [Opt('Frost fuera', 0, 127), Opt('Frost dentro', 128, 255)];
List<Opt> _strip() => [Opt('Apagado', 0, 3), Opt('Macros', 4, 255)];

List<Opt> _gobos16() {
  const r = [
    [9, 17], [18, 26], [27, 35], [36, 44], [45, 53], [54, 63], [64, 72],
    [73, 81], [82, 90], [91, 99], [100, 108], [109, 117], [118, 127]
  ];
  return [
    Opt('Abierto', 0, 8),
    for (var i = 0; i < 13; i++) Opt('Gobo ${i + 1}', r[i][0], r[i][1]),
    Opt('Rotación adelante', 128, 191),
    Opt('Rotación reversa', 192, 255),
  ];
}

List<Opt> _gobos20() => [
      Opt('Abierto', 0, 4),
      for (var i = 0; i < 13; i++) Opt('Gobo ${i + 1}', 5 + 5 * i, 9 + 5 * i),
      Opt('Rotación adelante', 70, 130),
      Opt('Rotación reversa', 131, 190),
      for (var i = 0; i < 13; i++)
        Opt('Gobo ${i + 1} shake', 191 + 5 * i, 195 + 5 * i),
    ];

// Atajos que imitan los botones de colores del control remoto del Bee.
// Valores de canal del Bee (modo 24): 10 dimmer, 11 strobe, 12-15 ojos RGBW,
// 16-19 haz RGBW, 20/21 láser rojo/verde, 22/23 strobe blanco/dorado, 24 macros.
Preset _beeColor(String name,
    {int r = 0, int g = 0, int b = 0, int w = 0, int lr = 0, int lg = 0,
     int sw = 0, int sd = 0, int macro = 0}) =>
    Preset(name, {
      10: 255, 11: 0,
      12: r, 13: g, 14: b, 15: w,
      16: r, 17: g, 18: b, 19: w,
      20: lr, 21: lg, 22: sw, 23: sd, 24: macro,
    });

List<Profile> builtinProfiles() {
  final cab16 = Mode('16 canales', [
    _f('Pan'),
    _f('Tilt'),
    _f('Pan fino'),
    _f('Tilt fino'),
    _f('Velocidad Pan/Tilt'),
    _s('Tira LED', _strip()),
    _s('Strobe', _strobe()),
    _f('Dimmer'),
    _f('Rueda de color'), // falta la tabla "4.1 Color Wheel" del manual
    _f('Color fino'),
    _s('Gobo', _gobos16()),
    _s('Gobo shake', [Opt('Sin shake', 0, 3), Opt('Shake lento→rápido', 4, 191)]),
    _f('Foco'),
    _s('Prisma', _prisma()),
    _s('Frost', _frost()),
    _s('Reset / lámpara', [
      Opt('Sin función', 0, 99),
      Opt('Lámpara OFF', 100, 105),
      Opt('Sin función (2)', 106, 199),
      Opt('Lámpara ON', 200, 205),
      Opt('Sin función (3)', 206, 239),
      Opt('Reset equipo', 240, 255),
    ]),
  ]);

  final cab20 = Mode('20 canales', [
    _f('Rueda de color'), // falta la tabla "4.1 Color Wheel" del manual
    _s('Strobe', _strobe()),
    _f('Dimmer'),
    _s('Gobo', _gobos20()),
    _s('Prisma', _prisma()),
    _s('Frost', _frost()),
    _s('Efecto combinado', [
      Opt('Sin función', 0, 10),
      Opt('Efectos combinados', 11, 255),
    ]),
    _s('Tira LED', _strip()),
    _f('Foco'),
    _f('Pan'),
    _f('Pan fino'),
    _f('Tilt'),
    _f('Tilt fino'),
    _f('Color fino'),
    _s('Reset', [
      Opt('Sin acción', 0, 100),
      Opt('Reset Pan/Tilt', 101, 150),
      Opt('Reset efectos', 151, 200),
      Opt('Reset total', 201, 255),
    ]),
    _s('Control de lámpara', [
      Opt('Sin acción', 0, 25),
      Opt('Lámpara OFF', 26, 100),
      Opt('Lámpara ON', 101, 255),
    ]),
    _f('Velocidad XY'),
    _f('Velocidad color'),
    _f('Velocidad foco'),
    _f('Velocidad gobo'),
  ]);

  final bee24 = Mode('24 canales', [
    _f('Eje X'),
    _f('Velocidad eje X'),
    _s('Rotación de los ojos', [
      Opt('Posición 0-360°', 0, 127),
      Opt('Giro adelante lento→rápido', 128, 191),
      Opt('Giro reversa lento→rápido', 192, 255),
    ]),
    _f('Motor haz 1'),
    _f('Motor haz 2'),
    _f('Motor haz 3'),
    _f('Motor haz 4'),
    _f('Motor haz 5'),
    _f('Motor haz 6'),
    _f('Dimmer total'),
    _s('Strobe', [
      Opt('Sin función', 0, 9),
      Opt('Strobe ojos y haz lento→rápido', 10, 255),
    ]),
    _f('Ojos rojo'),
    _f('Ojos verde'),
    _f('Ojos azul'),
    _f('Ojos blanco'),
    _f('Haz rojo'),
    _f('Haz verde'),
    _f('Haz azul'),
    _f('Haz blanco'),
    _f('Láser rojo'),
    _f('Láser verde'),
    _f('Strobe luz blanca'),
    _f('Strobe luz dorada'),
    _s('Macros', [
      Opt('Sin función', 0, 50),
      Opt('Auto aleatorio', 51, 150),
      Opt('Activado por voz', 151, 250),
      Opt('Reset (3 segundos)', 251, 255),
    ]),
  ]);

  bee24.presets = [
    _beeColor('1 Rojo', r: 255),
    _beeColor('2 Verde', g: 255),
    _beeColor('3 Azul', b: 255),
    _beeColor('4 Blanco', w: 255),
    _beeColor('5 Láser rojo', lr: 255),
    _beeColor('6 Láser verde', lg: 255),
    _beeColor('7 Strobe blanco + dorado', sw: 200, sd: 200),
    _beeColor('Auto aleatorio', macro: 100),
    _beeColor('Activado por voz', macro: 200),
    Preset('Todo apagado', {for (var i = 10; i <= 24; i++) i: 0}),
  ];

  // Modo de 26 canales: agrega los 2 canales de la tira de luz
  final bee26 = Mode.fromJson(
      Map<String, dynamic>.from(jsonDecode(jsonEncode(bee24.toJson())) as Map));
  bee26.name = '26 canales';
  bee26.chans.add(_s('Tira de luz (efecto)', [
    Opt('Sin función', 0, 4),
    Opt('Selección de efecto', 5, 255),
  ]));
  bee26.chans.add(_f('Tira de luz (velocidad)'));
  bee26.renumber();

  return [
    Profile('cabezal', 'Cabezal móvil', 'Cabezal', [cab16, cab20],
        builtIn: true),
    Profile('bee', 'Bee eyes six-armed little King Kong', 'Bee eyes',
        [bee24, bee26],
        builtIn: true),
    Profile('tachoA', 'Tachos grupo A (TA)', 'Tachos', [Mode('Panel RGB', [])],
        builtIn: true, panel: 'rgb', suffix: 'TA'),
    Profile('tachoB', 'Tachos grupo B (TB)', 'Tachos', [Mode('Panel RGB', [])],
        builtIn: true, panel: 'rgb', suffix: 'TB'),
  ];
}

// =====================================================================
//  COMUNICACIÓN CON EL CONTROLADOR
//  La app original hace: POST http://192.168.4.1/send con JSON.
//  El formato exacto del JSON se configura en Ajustes (plantillas).
// =====================================================================

class DmxSettings {
  String ip = '192.168.4.1';
  String path = '/send';
  String mode = 'single'; // 'single' = un canal por envío, 'bulk' = varios
  String singleTpl = '{"canal":{ch},"valor":{val}}';
  String bulkTpl = '{"data":{data}}';
  int bulkSize = 64;

  Map<String, dynamic> toJson() => {
        'ip': ip,
        'path': path,
        'mode': mode,
        'st': singleTpl,
        'bt': bulkTpl,
        'bs': bulkSize,
      };
  void fromJson(Map<String, dynamic> j) {
    ip = (j['ip'] ?? ip) as String;
    path = (j['path'] ?? path) as String;
    mode = (j['mode'] ?? mode) as String;
    singleTpl = (j['st'] ?? singleTpl) as String;
    bulkTpl = (j['bt'] ?? bulkTpl) as String;
    bulkSize = (j['bs'] ?? bulkSize) as int;
  }
}

class DmxService extends ChangeNotifier {
  final settings = DmxSettings();
  final List<int> universe = List<int>.filled(512, 0);
  final Set<int> _dirty = {};
  final Map<String, int> keyValues = {};
  final Map<String, int> _dirtyKeys = {};
  Timer? _timer;
  bool _busy = false;
  String log = 'Todavía no se envió nada';
  bool? online;

  void setChannel(int ch, int v) {
    if (ch < 1 || ch > 512) return;
    universe[ch - 1] = v.clamp(0, 255).toInt();
    _dirty.add(ch);
    _kick();
  }

  void setKeys(Map<String, int> m) {
    for (final e in m.entries) {
      final x = e.value.clamp(0, 255).toInt();
      keyValues[e.key] = x;
      _dirtyKeys[e.key] = x;
    }
    _kick();
  }

  // Envío por nombre, como hace la app original: {"dimmerTA":255}
  void setKey(String key, int v) {
    final x = v.clamp(0, 255).toInt();
    keyValues[key] = x;
    _dirtyKeys[key] = x;
    _kick();
  }

  void _kick() {
    if (_timer != null || _busy) return;
    _timer = Timer(const Duration(milliseconds: 40), _flush);
  }

  Future<void> _flush() async {
    _timer = null;
    _busy = true;
    try {
      if (settings.mode == 'bulk') {
        _dirty.clear();
        await _post(_renderBulk());
      } else {
        final list = _dirty.toList()..sort();
        _dirty.clear();
        for (final ch in list) {
          await _post(_renderSingle(ch, universe[ch - 1]));
        }
      }
      final keys = Map<String, int>.from(_dirtyKeys);
      _dirtyKeys.clear();
      if (keys.isNotEmpty) {
        await _post(jsonEncode(keys)); // ej. {"rojoTA":255,"verdeTA":0}
      }
    } finally {
      _busy = false;
    }
    if (_dirty.isNotEmpty || _dirtyKeys.isNotEmpty) _kick();
  }

  String _renderSingle(int ch, int v) =>
      settings.singleTpl.replaceAll('{ch}', '$ch').replaceAll('{val}', '$v');

  String _renderBulk() {
    final n = settings.bulkSize.clamp(1, 512).toInt();
    return settings.bulkTpl
        .replaceAll('{data}', jsonEncode(universe.sublist(0, n)));
  }

  Future<String> _post(String body) async {
    final path = settings.path.startsWith('/') ? settings.path : '/${settings.path}';
    final uri = Uri.parse('http://${settings.ip}$path');
    try {
      final r = await http
          .post(uri,
              headers: {'content-type': 'application/json'}, body: body)
          .timeout(const Duration(seconds: 2));
      online = r.statusCode == 200;
      log = 'POST $uri\n$body\n→ ${r.statusCode} ${r.body}';
    } catch (e) {
      online = false;
      log = 'POST $uri\n$body\n→ ERROR: $e';
    }
    notifyListeners();
    return log;
  }

  // Prueba segura: manda canal 512 = 0 (casi nunca se usa).
  Future<String> test() => _post(_renderSingle(512, 0));
}

// =====================================================================
//  ESTADO DE LA APP Y GUARDADO
// =====================================================================

class AppState extends ChangeNotifier {
  final dmx = DmxService();
  final List<Profile> builtin = builtinProfiles();
  List<Profile> custom = [];
  List<Fixture> fixtures = [];

  List<Profile> get profiles => [...builtin, ...custom];

  Profile? profileOf(String id) {
    for (final p in profiles) {
      if (p.id == id) return p;
    }
    return null;
  }

  Mode? modeOf(Fixture f) {
    final p = profileOf(f.profileId);
    if (p == null || p.modes.isEmpty) return null;
    return p.modes[f.mode < p.modes.length ? f.mode : 0];
  }

  int nextAddress() {
    var n = 1;
    for (final f in fixtures) {
      final m = modeOf(f);
      final end = f.address + (m == null ? 1 : m.chans.length);
      if (end > n) n = end;
    }
    return n > 512 ? 1 : n;
  }

  Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    try {
      final c = sp.getString('custom');
      if (c != null) {
        custom = (jsonDecode(c) as List)
            .map((e) => Profile.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
      }
      final f = sp.getString('fixtures');
      if (f != null) {
        fixtures = (jsonDecode(f) as List)
            .map((e) => Fixture.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
      }
      final s = sp.getString('settings');
      if (s != null) {
        dmx.settings.fromJson(Map<String, dynamic>.from(jsonDecode(s) as Map));
      }
    } catch (_) {}
  }

  Future<void> save() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('custom', jsonEncode(custom.map((p) => p.toJson()).toList()));
    await sp.setString('fixtures', jsonEncode(fixtures.map((f) => f.toJson()).toList()));
    await sp.setString('settings', jsonEncode(dmx.settings.toJson()));
    notifyListeners();
  }

  void saveProfile(Profile p) {
    final i = custom.indexWhere((e) => e.id == p.id);
    if (i >= 0) {
      custom[i] = p;
    } else {
      custom.add(p);
    }
    save();
  }
}

final app = AppState();

// =====================================================================
//  PANTALLAS
// =====================================================================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await app.load();
  runApp(const DmxApp());
}

class DmxApp extends StatelessWidget {
  const DmxApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DMX Control',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.deepPurple,
      ),
      home: const HomeScreen(),
    );
  }
}

// ---------------------------- Inicio ----------------------------------

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([app, app.dmx]),
      builder: (context, _) {
        final on = app.dmx.online;
        return Scaffold(
          appBar: AppBar(
            title: const Text('DMX Control'),
            actions: [
              Icon(
                on == null ? Icons.wifi_find : (on ? Icons.wifi : Icons.wifi_off),
                color: on == null ? null : (on ? Colors.greenAccent : Colors.redAccent),
              ),
              IconButton(
                tooltip: 'Tipos de equipo',
                icon: const Icon(Icons.tune),
                onPressed: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const ProfilesScreen())),
              ),
              IconButton(
                tooltip: 'Conexión',
                icon: const Icon(Icons.settings),
                onPressed: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const SettingsScreen())),
              ),
            ],
          ),
          body: app.fixtures.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Todavía no hay equipos.\nToca "Agregar equipo" para empezar.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(8),
                  children: [
                    for (final f in app.fixtures) _fixtureCard(context, f),
                  ],
                ),
          floatingActionButton: FloatingActionButton.extended(
            icon: const Icon(Icons.add),
            label: const Text('Agregar equipo'),
            onPressed: () => addFixtureDialog(context),
          ),
        );
      },
    );
  }

  Widget _fixtureCard(BuildContext context, Fixture f) {
    final p = app.profileOf(f.profileId);
    final m = app.modeOf(f);
    final n = m?.chans.length ?? 0;
    return Card(
      child: ListTile(
        title: Text(f.name),
        subtitle: Text((p?.panel ?? '').isNotEmpty
            ? '${p!.name} · Panel RGB'
            : '${p?.name ?? "Tipo borrado"} · ${m?.name ?? ""}\nDMX ${f.address}-${f.address + n - 1}'),
        isThreeLine: true,
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline),
          onPressed: () async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: Text('¿Quitar "${f.name}"?'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancelar')),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Quitar')),
                ],
              ),
            );
            if (ok == true) {
              app.fixtures.remove(f);
              app.save();
            }
          },
        ),
        onTap: m == null
            ? null
            : () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => (p?.panel ?? '').isNotEmpty
                        ? RgbPanelScreen(f, p!.suffix)
                        : ControlScreen(f))),
      ),
    );
  }
}

Future<void> addFixtureDialog(BuildContext context) async {
  final nameC = TextEditingController();
  final addrC = TextEditingController(text: '${app.nextAddress()}');
  Profile prof = app.profiles.first;
  int mode = 0;
  await showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) => AlertDialog(
        title: const Text('Agregar equipo'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameC,
                decoration: const InputDecoration(labelText: 'Nombre (opcional)'),
              ),
              const SizedBox(height: 8),
              DropdownButton<Profile>(
                isExpanded: true,
                value: prof,
                items: [
                  for (final p in app.profiles)
                    DropdownMenuItem(value: p, child: Text('${p.name} (${p.category})')),
                ],
                onChanged: (p) {
                  if (p != null) {
                    setS(() {
                      prof = p;
                      mode = 0;
                    });
                  }
                },
              ),
              DropdownButton<int>(
                isExpanded: true,
                value: mode,
                items: [
                  for (var i = 0; i < prof.modes.length; i++)
                    DropdownMenuItem(
                      value: i,
                      child: Text('${prof.modes[i].name} (${prof.modes[i].chans.length} canales)'),
                    ),
                ],
                onChanged: (m) {
                  if (m != null) setS(() => mode = m);
                },
              ),
              TextField(
                controller: addrC,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Dirección DMX inicial (1-512)'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(
            onPressed: () {
              final a = (int.tryParse(addrC.text) ?? 1).clamp(1, 512).toInt();
              final name = nameC.text.trim().isEmpty ? prof.name : nameC.text.trim();
              app.fixtures.add(Fixture(
                DateTime.now().microsecondsSinceEpoch.toString(),
                name,
                prof.id,
                mode,
                a,
              ));
              app.save();
              Navigator.pop(ctx);
            },
            child: const Text('Agregar'),
          ),
        ],
      ),
    ),
  );
}

// ------------------------ Control de un equipo -------------------------

class ControlScreen extends StatefulWidget {
  final Fixture fixture;
  const ControlScreen(this.fixture, {super.key});
  @override
  State<ControlScreen> createState() => _ControlScreenState();
}

class _ControlScreenState extends State<ControlScreen> {
  Fixture get fixture => widget.fixture;

  int _current(Chan c) {
    if (c.key.isNotEmpty) return app.dmx.keyValues[c.key] ?? 0;
    final a = fixture.address + c.off - 1;
    return (a >= 1 && a <= 512) ? app.dmx.universe[a - 1] : 0;
  }

  void _set(Chan c, int v) {
    if (c.key.isNotEmpty) {
      app.dmx.setKey(c.key, v);
    } else {
      app.dmx.setChannel(fixture.address + c.off - 1, v);
    }
  }

  void _apply(Mode mode, Preset p) {
    for (final c in mode.chans) {
      final v = p.vals[c.off];
      if (v != null) _set(c, v);
    }
    setState(() {});
  }

  Future<void> _saveScene(Mode mode) async {
    final c = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Guardar escena actual'),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Nombre de la escena'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Guardar')),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    fixture.mine.add(Preset(name.trim(), {for (final ch in mode.chans) ch.off: _current(ch)}));
    await app.save();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final mode = app.modeOf(fixture);
    if (mode == null) {
      return Scaffold(
        appBar: AppBar(title: Text(fixture.name)),
        body: const Center(child: Text('Este equipo no tiene un tipo válido.')),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(fixture.name),
        actions: [
          IconButton(
            tooltip: 'Todo a cero',
            icon: const Icon(Icons.power_settings_new),
            onPressed: () {
              for (final c in mode.chans) {
                _set(c, 0);
              }
              setState(() {});
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(8),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Atajos y escenas',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final p in mode.presets)
                        ActionChip(label: Text(p.name), onPressed: () => _apply(mode, p)),
                      for (final p in fixture.mine)
                        InputChip(
                          label: Text(p.name),
                          onPressed: () => _apply(mode, p),
                          onDeleted: () {
                            fixture.mine.remove(p);
                            app.save();
                            setState(() {});
                          },
                        ),
                      ActionChip(
                        avatar: const Icon(Icons.add, size: 18),
                        label: const Text('Guardar escena actual'),
                        onPressed: () => _saveScene(mode),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          for (final c in mode.chans)
            ChannelTile(
              key: ValueKey('${fixture.id}-${c.off}'),
              abs: fixture.address + c.off - 1,
              ch: c,
            ),
        ],
      ),
    );
  }
}

class ChannelTile extends StatefulWidget {
  final int abs;
  final Chan ch;
  const ChannelTile({super.key, required this.abs, required this.ch});
  @override
  State<ChannelTile> createState() => _ChannelTileState();
}

class _ChannelTileState extends State<ChannelTile> {
  int get v {
    if (widget.ch.key.isNotEmpty) return app.dmx.keyValues[widget.ch.key] ?? 0;
    return (widget.abs >= 1 && widget.abs <= 512) ? app.dmx.universe[widget.abs - 1] : 0;
  }

  void setV(int x) {
    if (widget.ch.key.isNotEmpty) {
      app.dmx.setKey(widget.ch.key, x);
    } else {
      app.dmx.setChannel(widget.abs, x);
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final ch = widget.ch;
    final value = v;
    Opt? sel;
    for (final o in ch.opts) {
      if (value >= o.from && value <= o.to) {
        sel = o;
        break;
      }
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('CH${ch.off} · ${ch.name}',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
                Text(ch.key.isNotEmpty ? '${ch.key} = $value' : 'DMX ${widget.abs} = $value'),
              ],
            ),
            if (!ch.isSelect)
              Slider(
                value: value.toDouble().clamp(ch.min.toDouble(), ch.max.toDouble()).toDouble(),
                min: ch.min.toDouble(),
                max: ch.max.toDouble(),
                onChanged: (d) => setV(d.round()),
              ),
            if (ch.isSelect) ...[
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final o in ch.opts)
                    ChoiceChip(
                      label: Text(o.label),
                      selected: identical(o, sel),
                      onSelected: (_) => setV(o.from),
                    ),
                ],
              ),
              if (sel != null && sel.to > sel.from)
                Slider(
                  value: value.toDouble().clamp(sel.from.toDouble(), sel.to.toDouble()).toDouble(),
                  min: sel.from.toDouble(),
                  max: sel.to.toDouble(),
                  onChanged: (d) => setV(d.round()),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

// ------------------------- Tipos de equipo -----------------------------

class ProfilesScreen extends StatelessWidget {
  const ProfilesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Tipos de equipo')),
        body: ListView(
          padding: const EdgeInsets.all(8),
          children: [
            for (final p in app.profiles)
              Card(
                child: ListTile(
                  title: Text(p.name),
                  subtitle: Text(
                      '${p.category} · ${p.modes.map((m) => m.name).join(", ")}${p.builtIn ? " · incluido" : ""}'),
                  trailing: p.builtIn
                      ? IconButton(
                          tooltip: 'Duplicar para editar',
                          icon: const Icon(Icons.copy),
                          onPressed: () {
                            final c = p.copy();
                            c.id = 'c${DateTime.now().microsecondsSinceEpoch}';
                            c.name = '${p.name} (copia)';
                            Navigator.push(context,
                                MaterialPageRoute(builder: (_) => ProfileEditor(c)));
                          },
                        )
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit),
                              onPressed: () => Navigator.push(context,
                                  MaterialPageRoute(builder: (_) => ProfileEditor(p))),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () {
                                final used = app.fixtures.any((f) => f.profileId == p.id);
                                if (used) {
                                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                                      content: Text('Hay equipos usando este tipo. Quítalos primero.')));
                                  return;
                                }
                                app.custom.remove(p);
                                app.save();
                              },
                            ),
                          ],
                        ),
                  onTap: p.builtIn
                      ? null
                      : () => Navigator.push(context,
                          MaterialPageRoute(builder: (_) => ProfileEditor(p))),
                ),
              ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          icon: const Icon(Icons.add),
          label: const Text('Nuevo tipo'),
          onPressed: () {
            final p = Profile(
              'c${DateTime.now().microsecondsSinceEpoch}',
              'Nuevo equipo',
              'Otro',
              [
                Mode('Modo 1', [_f('Canal 1'), _f('Canal 2'), _f('Canal 3')])
              ],
            );
            Navigator.push(context, MaterialPageRoute(builder: (_) => ProfileEditor(p)));
          },
        ),
      ),
    );
  }
}

class ProfileEditor extends StatefulWidget {
  final Profile profile;
  const ProfileEditor(this.profile, {super.key});
  @override
  State<ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends State<ProfileEditor> {
  late Profile p;
  int mi = 0;

  @override
  void initState() {
    super.initState();
    p = widget.profile.copy();
  }

  Mode get mode => p.modes[mi];

  Future<String?> _ask(String title, String initial) async {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(controller: c, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Aceptar')),
        ],
      ),
    );
  }

  Future<void> _editOpts(Chan ch) async {
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text('Opciones de ${ch.name}'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final o in ch.opts)
                  Row(
                    key: ObjectKey(o),
                    children: [
                      Expanded(
                        flex: 3,
                        child: TextFormField(
                          initialValue: o.label,
                          decoration: const InputDecoration(labelText: 'Nombre'),
                          onChanged: (v) => o.label = v,
                        ),
                      ),
                      const SizedBox(width: 4),
                      SizedBox(
                        width: 52,
                        child: TextFormField(
                          initialValue: '${o.from}',
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'Desde'),
                          onChanged: (v) => o.from = (int.tryParse(v) ?? o.from).clamp(0, 255).toInt(),
                        ),
                      ),
                      const SizedBox(width: 4),
                      SizedBox(
                        width: 52,
                        child: TextFormField(
                          initialValue: '${o.to}',
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'Hasta'),
                          onChanged: (v) => o.to = (int.tryParse(v) ?? o.to).clamp(0, 255).toInt(),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => setS(() => ch.opts.remove(o)),
                      ),
                    ],
                  ),
                TextButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('Agregar opción'),
                  onPressed: () => setS(() => ch.opts.add(Opt('Opción', 0, 255))),
                ),
              ],
            ),
          ),
          actions: [
            FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Listo')),
          ],
        ),
      ),
    );
    if (ch.opts.isEmpty) ch.opts = [Opt('Apagado', 0, 9), Opt('Encendido', 10, 255)];
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Editar tipo de equipo'),
        actions: [
          IconButton(
            tooltip: 'Guardar',
            icon: const Icon(Icons.save),
            onPressed: () {
              if (p.name.trim().isEmpty) p.name = 'Equipo sin nombre';
              app.saveProfile(p);
              Navigator.pop(context);
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(8),
        children: [
          TextFormField(
            initialValue: p.name,
            decoration: const InputDecoration(labelText: 'Nombre del equipo'),
            onChanged: (v) => p.name = v,
          ),
          TextFormField(
            initialValue: p.category,
            decoration: const InputDecoration(labelText: 'Categoría (cabezal, tacho, spider, láser...)'),
            onChanged: (v) => p.category = v,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: DropdownButton<int>(
                  isExpanded: true,
                  value: mi,
                  items: [
                    for (var i = 0; i < p.modes.length; i++)
                      DropdownMenuItem(
                        value: i,
                        child: Text('${p.modes[i].name} (${p.modes[i].chans.length} canales)'),
                      ),
                  ],
                  onChanged: (v) => setState(() => mi = v ?? 0),
                ),
              ),
              IconButton(
                tooltip: 'Renombrar modo',
                icon: const Icon(Icons.edit),
                onPressed: () async {
                  final r = await _ask('Nombre del modo', mode.name);
                  if (r != null && r.trim().isNotEmpty) setState(() => mode.name = r.trim());
                },
              ),
              IconButton(
                tooltip: 'Nuevo modo',
                icon: const Icon(Icons.add_box),
                onPressed: () async {
                  final r = await _ask('Nombre del nuevo modo (ej. 24 canales)', '');
                  if (r != null && r.trim().isNotEmpty) {
                    setState(() {
                      p.modes.add(Mode(r.trim(), [_f('Canal 1')]));
                      mi = p.modes.length - 1;
                    });
                  }
                },
              ),
              IconButton(
                tooltip: 'Borrar modo',
                icon: const Icon(Icons.delete_outline),
                onPressed: p.modes.length < 2
                    ? null
                    : () => setState(() {
                          p.modes.removeAt(mi);
                          mi = 0;
                        }),
              ),
            ],
          ),
          for (final ch in mode.chans)
            Card(
              key: ObjectKey(ch),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Text('CH${ch.off}'),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextFormField(
                            initialValue: ch.name,
                            decoration: const InputDecoration(labelText: 'Nombre del canal'),
                            onChanged: (v) => ch.name = v,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => setState(() {
                            mode.chans.remove(ch);
                            mode.renumber();
                          }),
                        ),
                      ],
                    ),
                    TextFormField(
                      initialValue: ch.key,
                      decoration: const InputDecoration(
                          labelText: 'Clave JSON (opcional, ej. dimmerTA)'),
                      onChanged: (v) => ch.key = v.trim(),
                    ),
                    Row(
                      children: [
                        SegmentedButton<bool>(
                          segments: const [
                            ButtonSegment(value: false, label: Text('Fader')),
                            ButtonSegment(value: true, label: Text('Selector')),
                          ],
                          selected: {ch.isSelect},
                          onSelectionChanged: (s) => setState(() {
                            if (s.first) {
                              if (ch.opts.isEmpty) {
                                ch.opts = [Opt('Apagado', 0, 9), Opt('Encendido', 10, 255)];
                              }
                            } else {
                              ch.opts = [];
                            }
                          }),
                        ),
                        const SizedBox(width: 8),
                        if (ch.isSelect)
                          OutlinedButton(
                            onPressed: () => _editOpts(ch),
                            child: Text('Opciones (${ch.opts.length})'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          TextButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('Agregar canal'),
            onPressed: () => setState(() {
              mode.chans.add(_f('Canal ${mode.chans.length + 1}'));
              mode.renumber();
            }),
          ),
          const SizedBox(height: 80),
        ],
      ),
    );
  }
}

// ----------------------------- Conexión --------------------------------

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final s = app.dmx.settings;
  late final TextEditingController ipC = TextEditingController(text: s.ip);
  late final TextEditingController pathC = TextEditingController(text: s.path);
  late final TextEditingController singleC = TextEditingController(text: s.singleTpl);
  late final TextEditingController bulkC = TextEditingController(text: s.bulkTpl);
  late final TextEditingController sizeC = TextEditingController(text: '${s.bulkSize}');
  late String mode = s.mode;
  String result = '';

  void apply() {
    s.ip = ipC.text.trim();
    s.path = pathC.text.trim();
    s.mode = mode;
    s.singleTpl = singleC.text;
    s.bulkTpl = bulkC.text;
    s.bulkSize = int.tryParse(sizeC.text) ?? 64;
    app.save();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Conexión con el controlador')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const Text(
              'Conéctate primero al WiFi del controlador (DMX_CEL o DMX_CONSOLE).'),
          TextField(
            controller: ipC,
            decoration: const InputDecoration(labelText: 'IP del controlador'),
          ),
          TextField(
            controller: pathC,
            decoration: const InputDecoration(labelText: 'Ruta'),
          ),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'single', label: Text('Un canal por envío')),
              ButtonSegment(value: 'bulk', label: Text('Varios canales')),
            ],
            selected: {mode},
            onSelectionChanged: (v) => setState(() => mode = v.first),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: singleC,
            decoration: const InputDecoration(
                labelText: 'Formato JSON (un canal)',
                helperText: 'Usa {ch} para el canal y {val} para el valor'),
          ),
          Wrap(
            spacing: 6,
            children: [
              for (final t in const [
                '{"ch":{ch},"val":{val}}',
                '{"canal":{ch},"valor":{val}}',
                '{"channel":{ch},"value":{val}}',
                '{"ch{ch}":{val}}',
                '{"ch":{ch},"v":{val}}',
              ])
                ActionChip(
                  label: Text(t),
                  onPressed: () => setState(() => singleC.text = t),
                ),
            ],
          ),
          TextField(
            controller: bulkC,
            decoration: const InputDecoration(
                labelText: 'Formato JSON (varios canales)',
                helperText: 'Usa {data} para la lista de valores'),
          ),
          Wrap(
            spacing: 6,
            children: [
              for (final t in const [
                '{"data":{data}}',
                '{"d":{data}}',
                '{"channels":{data}}',
                '{"values":{data}}',
              ])
                ActionChip(
                  label: Text(t),
                  onPressed: () => setState(() => bulkC.text = t),
                ),
            ],
          ),
          TextField(
            controller: sizeC,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Cantidad de canales a enviar (varios)'),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            icon: const Icon(Icons.network_check),
            label: const Text('Guardar y probar conexión'),
            onPressed: () async {
              apply();
              setState(() => result = 'Enviando...');
              final r = await app.dmx.test();
              if (mounted) setState(() => result = r);
            },
          ),
          const SizedBox(height: 12),
          const Text('Último envío:', style: TextStyle(fontWeight: FontWeight.bold)),
          SelectableText(result.isEmpty ? app.dmx.log : result),
        ],
      ),
    );
  }
}


// ------------------- Panel RGB (tachos) --------------------------------
// Usa las órdenes con nombre del controlador: dimmerTA, rojoTA, verdeTA,
// azulTA, stroboTA, speedTA, delayTA, gradientTA (y lo mismo con TB).

// ----------------------------- Estilos ---------------------------------
const Color _cRojo = Color(0xFFFF0000);
const Color _cVerde = Color(0xFF00FF00);
const Color _cAzul = Color(0xFF0000FF);
const Color _cAmarillo = Color(0xFFFFE600);
const Color _cCian = Color(0xFF00FFFF);
const Color _cVioleta = Color(0xFF8A2BE2);
const Color _cMagenta = Color(0xFFFF00FF);
const Color _cBlanco = Color(0xFFFFFFFF);
const Color _cNegro = Color(0xFF000000);

Color _scale(Color c, double k) {
  final x = k.clamp(0.0, 1.0).toDouble();
  return Color.fromARGB(
      255, (c.red * x).round(), (c.green * x).round(), (c.blue * x).round());
}

Color _mix(Color a, Color b, double t) => Color.fromARGB(
      255,
      (a.red + (b.red - a.red) * t).round(),
      (a.green + (b.green - a.green) * t).round(),
      (a.blue + (b.blue - a.blue) * t).round(),
    );

Color Function(double, Color) _closeSeq(List<Color> cols) => (p, base) {
      final n = cols.length;
      final i = math.min((p * n).floor(), n - 1);
      return _scale(cols[i], 1 - (p * n - i));
    };

Color Function(double, Color) _openSeq(List<Color> cols) => (p, base) {
      final n = cols.length;
      final i = math.min((p * n).floor(), n - 1);
      return _scale(cols[i], p * n - i);
    };

Color Function(double, Color) _cross(List<Color> cols) => (p, base) {
      final n = cols.length;
      final i = math.min((p * n).floor(), n - 1);
      return _mix(cols[i], cols[(i + 1) % n], p * n - i);
    };

Color Function(double, Color) _steps(List<Color> cols) => (p, base) {
      return cols[math.min((p * cols.length).floor(), cols.length - 1)];
    };

class StyleDef {
  final String cat;
  final String name;
  final Color Function(double, Color) fn;
  const StyleDef(this.cat, this.name, this.fn);
}

final List<StyleDef> kStyles = [
  StyleDef('Básico', 'Arcoíris', (p, b) => HSVColor.fromAHSV(1, p * 360, 1, 1).toColor()),
  StyleDef('Básico', 'Cambio rojo-verde-azul', _steps([_cRojo, _cVerde, _cAzul])),
  StyleDef('Básico', 'Cambio 8 colores',
      _steps([_cRojo, _cAmarillo, _cVerde, _cCian, _cAzul, _cVioleta, _cMagenta, _cBlanco])),
  StyleDef('Básico', 'Respirar (color actual)',
      (p, b) => _scale(b, 0.5 + 0.5 * math.sin(2 * math.pi * p - math.pi / 2))),
  StyleDef('Abrir/Cerrar', 'Cierre rojo', _closeSeq([_cRojo])),
  StyleDef('Abrir/Cerrar', 'Cortina rojo', _openSeq([_cRojo])),
  StyleDef('Abrir/Cerrar', 'Cierre verde', _closeSeq([_cVerde])),
  StyleDef('Abrir/Cerrar', 'Cortina verde', _openSeq([_cVerde])),
  StyleDef('Abrir/Cerrar', 'Cierre azul', _closeSeq([_cAzul])),
  StyleDef('Abrir/Cerrar', 'Cortina azul', _openSeq([_cAzul])),
  StyleDef('Abrir/Cerrar', 'Cierre rojo-verde-azul', _closeSeq([_cRojo, _cVerde, _cAzul])),
  StyleDef('Abrir/Cerrar', 'Cortina rojo-verde-azul', _openSeq([_cRojo, _cVerde, _cAzul])),
  StyleDef('Abrir/Cerrar', 'Cierre amarillo-cian-violeta',
      _closeSeq([_cAmarillo, _cCian, _cVioleta])),
  StyleDef('Abrir/Cerrar', 'Cortina amarillo-cian-violeta',
      _openSeq([_cAmarillo, _cCian, _cVioleta])),
  StyleDef('Transición', 'Fundido rojo-verde-azul', _cross([_cRojo, _cVerde, _cAzul])),
  StyleDef('Transición', 'Fundido amarillo-cian-violeta',
      _cross([_cAmarillo, _cCian, _cVioleta])),
  StyleDef('Transición', 'Fundido rojo-azul', _cross([_cRojo, _cAzul])),
  StyleDef('Transición', 'Fundido verde-violeta', _cross([_cVerde, _cVioleta])),
  StyleDef('Otros', 'Parpadeo blanco', (p, b) => p < 0.5 ? _cBlanco : _cNegro),
  StyleDef('Otros', 'Parpadeo color actual', (p, b) => p < 0.5 ? b : _cNegro),
];

class RgbPanelScreen extends StatefulWidget {
  final Fixture fixture;
  final String suffix;
  const RgbPanelScreen(this.fixture, this.suffix, {super.key});
  @override
  State<RgbPanelScreen> createState() => _RgbPanelScreenState();
}

class _RgbPanelScreenState extends State<RgbPanelScreen> {
  double hue = 0;
  double sat = 1;
  double dimmer = 255;
  double strobe = 0;
  double fxSpeed = 50; // 0-100, como en Magic Lantern
  String styleCat = 'Básico';
  Color live = const Color(0xFF000000);
  double speedK = 0;
  double delayK = 0;
  double gradK = 0;
  bool on = true;
  String fx = 'none';
  Timer? _fx;
  int _idx = 0;

  String get sfx => widget.suffix;
  Fixture get fixture => widget.fixture;

  static const palette = <String, Color>{
    'Rojo': Color(0xFFFF0000),
    'Naranja': Color(0xFFFF7A00),
    'Amarillo': Color(0xFFFFE600),
    'Verde': Color(0xFF00FF00),
    'Cian': Color(0xFF00FFFF),
    'Azul': Color(0xFF0000FF),
    'Violeta': Color(0xFF8A2BE2),
    'Magenta': Color(0xFFFF00FF),
    'Blanco': Color(0xFFFFFFFF),
  };

  Color get color => HSVColor.fromAHSV(1, hue, sat, 1).toColor();

  void _sendColor() {
    final c = color;
    app.dmx.setKeys({
      'rojo$sfx': c.red,
      'verde$sfx': c.green,
      'azul$sfx': c.blue,
    });
  }

  void _setColor(Color c) {
    final h = HSVColor.fromColor(c);
    setState(() {
      hue = h.hue;
      sat = h.saturation;
    });
    _sendColor();
  }

  void _stopFx() {
    _fx?.cancel();
    _fx = null;
    fx = 'none';
  }

  void _startStyle(StyleDef st) {
    _fx?.cancel();
    _fx = null;
    setState(() => fx = st.name);
    final base = color;
    // velocidad 0 = ciclo de 20 s; velocidad 100 = ciclo de 1,5 s
    final cycleMs = (20000 - (fxSpeed / 100) * 18500).round();
    final start = DateTime.now();
    _fx = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final t = DateTime.now().difference(start).inMilliseconds;
      final pr = (t % cycleMs) / cycleMs;
      final c = st.fn(pr, base);
      app.dmx.setKeys({
        'rojo$sfx': c.red,
        'verde$sfx': c.green,
        'azul$sfx': c.blue,
      });
      if (mounted) setState(() => live = c);
    });
  }

  Future<void> _saveColor() async {
    final c = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Guardar color actual'),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Nombre'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Guardar')),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    final col = color;
    fixture.mine.add(Preset(name.trim(), {1: col.red, 2: col.green, 3: col.blue}));
    await app.save();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _fx?.cancel();
    super.dispose();
  }

  Widget _slider(String label, double v, ValueChanged<double> onChanged,
      {double min = 0, double max = 255, ValueChanged<double>? onEnd}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label: ${v.round()}'),
        Slider(value: v, min: min, max: max, onChanged: onChanged, onChangeEnd: onEnd),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(fixture.name)),
      body: ListView(
        padding: const EdgeInsets.all(8),
        children: [
          Card(
            child: SwitchListTile(
              title: const Text('Encendido'),
              value: on,
              onChanged: (v) {
                setState(() => on = v);
                app.dmx.setKey('dimmer$sfx', v ? (dimmer.round() < 1 ? 255 : dimmer.round()) : 0);
              },
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  ColorWheel(
                    hue: hue,
                    sat: sat,
                    onChanged: (h, s) {
                      _stopFx();
                      setState(() {
                        hue = h;
                        sat = s;
                      });
                      _sendColor();
                    },
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final e in palette.entries)
                        GestureDetector(
                          onTap: () {
                            _stopFx();
                            _setColor(e.value);
                          },
                          child: Tooltip(
                            message: e.key,
                            child: Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: e.value,
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white54, width: 2),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _slider('Dimmer (brillo)', dimmer, (v) {
                    setState(() {
                      dimmer = v;
                      on = v > 0;
                    });
                    app.dmx.setKey('dimmer$sfx', v.round());
                  }),
                  _slider('Strobo', strobe, (v) {
                    setState(() => strobe = v);
                    app.dmx.setKey('strobo$sfx', v.round());
                  }),
                ],
              ),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text('Estilos',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                      Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: live,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white54, width: 2),
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () => setState(_stopFx),
                        child: const Text('Detener'),
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final c in const ['Básico', 'Abrir/Cerrar', 'Transición', 'Otros'])
                        ChoiceChip(
                          label: Text(c),
                          selected: styleCat == c,
                          onSelected: (_) => setState(() => styleCat = c),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final st in kStyles)
                        if (st.cat == styleCat)
                          ChoiceChip(
                            label: Text(st.name),
                            selected: fx == st.name,
                            onSelected: (_) => _startStyle(st),
                          ),
                    ],
                  ),
                  _slider('Velocidad', fxSpeed, (v) => setState(() => fxSpeed = v),
                      min: 0, max: 100, onEnd: (_) {
                    for (final st in kStyles) {
                      if (st.name == fx) _startStyle(st);
                    }
                  }),
                  const Text(
                    'Todos los tachos del grupo reciben el mismo color, así que "cierre" y "cortina" se hacen como fundidos en el tiempo. Los estilos los genera la app: funcionan con la app abierta.',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Mis colores', style: TextStyle(fontWeight: FontWeight.bold)),
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final p in fixture.mine)
                        InputChip(
                          avatar: CircleAvatar(
                            backgroundColor: Color.fromARGB(
                                255, p.vals[1] ?? 0, p.vals[2] ?? 0, p.vals[3] ?? 0),
                          ),
                          label: Text(p.name),
                          onPressed: () {
                            _stopFx();
                            _setColor(Color.fromARGB(
                                255, p.vals[1] ?? 0, p.vals[2] ?? 0, p.vals[3] ?? 0));
                          },
                          onDeleted: () {
                            fixture.mine.remove(p);
                            app.save();
                            setState(() {});
                          },
                        ),
                      ActionChip(
                        avatar: const Icon(Icons.add, size: 18),
                        label: const Text('Guardar color actual'),
                        onPressed: _saveColor,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Card(
            child: ExpansionTile(
              title: const Text('Avanzado (órdenes del controlador, sin confirmar)'),
              childrenPadding: const EdgeInsets.all(12),
              children: [
                _slider('speed$sfx', speedK, (v) {
                  setState(() => speedK = v);
                  app.dmx.setKey('speed$sfx', v.round());
                }),
                _slider('delay$sfx', delayK, (v) {
                  setState(() => delayK = v);
                  app.dmx.setKey('delay$sfx', v.round());
                }),
                _slider('gradient$sfx', gradK, (v) {
                  setState(() => gradK = v);
                  app.dmx.setKey('gradient$sfx', v.round());
                }),
              ],
            ),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

class ColorWheel extends StatelessWidget {
  final double hue;
  final double sat;
  final void Function(double hue, double sat) onChanged;
  const ColorWheel(
      {super.key, required this.hue, required this.sat, required this.onChanged});

  void _handle(Offset p, double size) {
    final c = Offset(size / 2, size / 2);
    final d = p - c;
    var ang = math.atan2(d.dy, d.dx) * 180 / math.pi;
    if (ang < 0) ang += 360;
    final r = (d.distance / (size / 2)).clamp(0.0, 1.0).toDouble();
    onChanged(ang, r);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, cs) {
      final size = math.min(cs.maxWidth, 280.0);
      return Center(
        child: SizedBox(
          width: size,
          height: size,
          child: GestureDetector(
            onPanStart: (d) => _handle(d.localPosition, size),
            onPanUpdate: (d) => _handle(d.localPosition, size),
            onTapDown: (d) => _handle(d.localPosition, size),
            child: CustomPaint(painter: _WheelPainter(hue, sat)),
          ),
        ),
      );
    });
  }
}

class _WheelPainter extends CustomPainter {
  final double hue;
  final double sat;
  _WheelPainter(this.hue, this.sat);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    final rect = Rect.fromCircle(center: c, radius: r);
    final sweep = SweepGradient(colors: [
      for (var h = 0; h <= 360; h += 60)
        HSVColor.fromAHSV(1, h.toDouble(), 1, 1).toColor(),
    ]);
    canvas.drawCircle(c, r, Paint()..shader = sweep.createShader(rect));
    final radial = RadialGradient(
        colors: [Colors.white, Colors.white.withOpacity(0)]);
    canvas.drawCircle(c, r, Paint()..shader = radial.createShader(rect));
    final a = hue * math.pi / 180;
    final p = c + Offset(math.cos(a), math.sin(a)) * (sat * r);
    canvas.drawCircle(
        p,
        12,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3);
    canvas.drawCircle(p, 10, Paint()..color = HSVColor.fromAHSV(1, hue, sat, 1).toColor());
  }

  @override
  bool shouldRepaint(_WheelPainter o) => o.hue != hue || o.sat != sat;
}
