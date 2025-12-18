// tool/migrate.dart
import 'dart:io';
import 'package:yaml_edit/yaml_edit.dart';

/// Configuration
const String libDir = 'lib/generated/metadata/geocoding';
const String assetDir = 'lib/assets/geocoding';
const String loaderPath = 'lib/generated/metadata/geocoding_loader.dart';

void main() async {
  final dir = Directory(libDir);
  if (!dir.existsSync()) {
    print('❌ Error: Library directory not found at $libDir');
    exit(1);
  }

  print('🔍 Scanning source files...');
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart') && !f.path.endsWith('loader.dart'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  if (files.isEmpty) {
    print('⚠️ No metadata files found.');
    return;
  }

  await generateLoader(files);
  await generateAndRunExecutor(files);
  await ensureInitFunctionInRoot();
  await updatePubspec();
}

Future<void> updatePubspec() async {
  print('✏️ Updating pubspec.yaml...');
  const pubspecPath = 'pubspec.yaml';
  final pubspecFile = File(pubspecPath);
  if (!await pubspecFile.exists()) {
    print('⚠️ Could not find $pubspecPath.');
    return;
  }

  final content = await pubspecFile.readAsString();
  final yamlEditor = YamlEditor(content);

  // Ensure flutter dependency exists
  final deps = yamlEditor.parseAt(['dependencies']);
  if (deps.value['flutter'] == null) {
    print('  + Adding flutter dependency...');
    yamlEditor.update(['dependencies', 'flutter'], {'sdk': 'flutter'});
  } else {
    print('  ✅ Flutter dependency already exists.');
  }

  // Ensure assets are declared
  final assetPath = 'lib/assets/geocoding/';

  // Check if 'flutter' key exists at the root.
  final root = yamlEditor.parseAt([]);
  // root.value is a YamlMap which behaves like a Map.
  final hasFlutterKey = (root.value as Map).containsKey('flutter');

  if (!hasFlutterKey) {
    print('  + Adding flutter section with assets...');
    yamlEditor.update(['flutter'], {
      'assets': [assetPath]
    });
  } else {
    final assetsNode = yamlEditor.parseAt(['flutter', 'assets']);
    if (assetsNode.value == null) {
      print('  + Adding assets section to existing flutter block...');
      yamlEditor.update(['flutter', 'assets'], [assetPath]);
    } else {
      if (assetsNode.value is List) {
        final assets = List.from(assetsNode.value);
        if (!assets.contains(assetPath)) {
          print('  + Adding geocoding assets path...');
          yamlEditor.appendToList(['flutter', 'assets'], assetPath);
        } else {
          print('  ✅ Geocoding assets path already exists.');
        }
      }
    }
  }

  await pubspecFile.writeAsString(yamlEditor.toString());
  print('✅ pubspec.yaml updated successfully.');
}

Future<void> generateLoader(List<File> files) async {
  print('� Generating loader...');
  final loaderBuffer = StringBuffer();

  loaderBuffer.writeln("import 'dart:convert';");
  loaderBuffer.writeln("import 'package:flutter/services.dart';");

  for (var i = 0; i < files.length; i++) {
    final filename = files[i].uri.pathSegments.last;
    loaderBuffer.writeln("import 'geocoding/$filename' as lib_$i;");
  }

  loaderBuffer.writeln("\n/// Auto-generated loader for JSON data injection");
  loaderBuffer.writeln("class GeocodingLoader {");
  loaderBuffer.writeln(
      "  static const _assetPrefix = 'packages/dlibphonenumber/assets/geocoding';");
  loaderBuffer.writeln("\n  static Future<void> loadAll() async {");

  for (int i = 0; i < files.length; i++) {
    final file = files[i];
    final jsonName = file.uri.pathSegments.last.replaceAll('.dart', '.json');
    loaderBuffer.writeln("    await _load('$jsonName', lib_$i.map);");
  }

  loaderBuffer.writeln("  }");
  loaderBuffer.writeln("\n  static Future<void> _load(String jsonFile, Map<int, String> target) async {");
  loaderBuffer.writeln("    if (target.isNotEmpty) return;");
  loaderBuffer.writeln(
      "    final str = await rootBundle.loadString('\$_assetPrefix/\$jsonFile');");
  loaderBuffer.writeln("    final Map<String, dynamic> json = jsonDecode(str);");
  loaderBuffer.writeln("    target.addAll(json.map((k, v) => MapEntry(int.parse(k), v as String)));");
  loaderBuffer.writeln("  }");
  loaderBuffer.writeln("}");

  await File(loaderPath).writeAsString(loaderBuffer.toString());
  print('✅ Loader generated at $loaderPath');
}

Future<void> generateAndRunExecutor(List<File> files) async {
  final executorFile = File('tool/temp_executor.dart');
  final executorBuffer = StringBuffer();

  executorBuffer.writeln("import 'dart:convert';");
  executorBuffer.writeln("import 'dart:io';");

  for (int i = 0; i < files.length; i++) {
    final relativePath = '../${files[i].path.replaceAll('\\', '/')}';
    executorBuffer.writeln("import '$relativePath' as m$i;");
  }

  executorBuffer.writeln("\nvoid main() {");
  executorBuffer.writeln("  print('🚀 Starting data extraction and transformation...');");
  executorBuffer.writeln("  Directory('$assetDir').createSync(recursive: true);");

  for (int i = 0; i < files.length; i++) {
    final file = files[i];
    final filename = file.uri.pathSegments.last;
    final funcName = 'get${filename.replaceAll('.dart', '')}';
    final jsonName = filename.replaceAll('.dart', '.json');

    // 1. Export JSON by calling the function and converting keys to strings
    executorBuffer.writeln(
        "  File(\'$assetDir/$jsonName\').writeAsStringSync(jsonEncode(m$i.$funcName().map((k, v) => MapEntry(k.toString(), v))));");

    // 2. Rewrite the original file into a shell
    final shellContent = '''
// Generated Shell for $filename
// Data moved to $assetDir/$jsonName
Map<int, String> map = {};
Map<int, String> $funcName() => map;
''';
    executorBuffer.writeln(
        "  File('${file.path.replaceAll('\\', '/')}').writeAsStringSync('''$shellContent''');");
  }

  executorBuffer.writeln("  print('✅ Migration complete!');");
  executorBuffer.writeln("}");

  await executorFile.writeAsString(executorBuffer.toString());

  print('🔨 Compiling and running migration script...');
  final result = await Process.run('dart', ['run', 'tool/temp_executor.dart']);

  if (result.exitCode != 0) {
    print('❌ Execution failed:');
    print(result.stderr);
  } else {
    print(result.stdout);
  }

  // Clean up
  // await executorFile.delete();
}

Future<void> ensureInitFunctionInRoot() async {
  const rootLibPath = 'lib/dlibphonenumber.dart';
  final rootLibFile = File(rootLibPath);
  if (!await rootLibFile.exists()) {
    print('⚠️ Could not find $rootLibPath to add init function.');
    return;
  }

  var content = await rootLibFile.readAsString();
  const initFunctionName = 'dlibphonenumberInit';
  if (content.contains(initFunctionName)) {
    print('✅ Init function already exists in $rootLibPath.');
    return;
  }

  print('✏️ Adding init function to $rootLibPath...');
  const initFunctionContent = """

import 'generated/metadata/geocoding_loader.dart';
export 'generated/metadata/geocoding_loader.dart';

Future<void> dlibphonenumberInit() async {
  await GeocodingLoader.loadAll();
}
""";

  final sink = rootLibFile.openWrite(mode: FileMode.append);
  sink.write(initFunctionContent);
  await sink.close();
  print('✅ Init function added successfully.');
}

