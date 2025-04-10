import 'dart:convert';
import 'dart:io';
import 'package:api_request_generator/api_request_generator.dart';
import 'package:args/command_runner.dart';
import 'package:dart_style/dart_style.dart';

class GenerateSingleActionCommand extends Command {
  GenerateSingleActionCommand() {
    argParser.addOption('config',
        abbr: 'c', help: 'Path to the JSON config file', defaultsTo: 'action_config.json');
  }

  final logger = Logger();

  @override
  String get description => 'Generate a single action from a JSON config file';

  @override
  String get name => 'generate-single-action';

  @override
  void run() async {
    String configPath = argResults?['config'] ?? 'action_config.json';

    File configFile = File(configPath);
    if (!configFile.existsSync()) {
      logger.e('Error: Config file not found at $configPath');
      exit(1);
    }

    logger.i('Reading config from $configPath...');
    String configContent = configFile.readAsStringSync();
    Map<String, dynamic> config;
    try {
      config = jsonDecode(configContent) as Map<String, dynamic>;
    } catch (e) {
      logger.e('Error parsing JSON config file', error: e);
      exit(1);
    }

    // استخراج البيانات من الـ JSON
    String baseUrl = config['base_url'] as String? ?? 'https://default.api';
    String path = config['path'] as String? ?? '';
    String url = '$baseUrl$path';
    String method = config['method'] as String? ?? 'GET';
    String? token = config['token'] as String?;
    String outputDir =  (config['output_dir'] as String? ?? 'lib/actions');
    String actionName = (config['action_name'] as String?)?.trim().replaceAll(' ', '') ?? '';
    bool isAuth = config['is_auth'] as bool? ?? false;
    String authType = config['auth_type'] as String? ?? 'noauth';
    dynamic data = config['data'] ?? {};

    if (url.isEmpty || baseUrl.isEmpty) {
      logger.e('base_url and path cannot result in an empty URL');
      exit(1);
    }

    if (actionName.isEmpty) {
      actionName = path.split('/').lastWhere((part) => part.isNotEmpty, orElse: () => 'Action');
      logger.i('Generated action name from path: $actionName');
    }

    // التحقق من الـ Data (Body)
    dynamic processedBody = data is Map && data.isNotEmpty ? data : null;

    // التحقق من auth_type
    if (isAuth && !['noauth', 'bearer', 'basic'].contains(authType)) {
      logger.e('Invalid auth_type: $authType. Must be "noauth", "bearer", or "basic"');
      exit(1);
    }

    // جلب الـ Response
    String? responseBody = await fetchResponse(
      url: url,
      method: method,
      token: isAuth && token != null && token.isNotEmpty ? token : null,
      body: processedBody,
      authType: authType,
    );

    if (responseBody == null) {
      logger.e('Failed to fetch response for $url');
      exit(1);
    }

    // توليد الـ Action والـ Response
    String action = generateAction(
      name: actionName,
      method: method,
      body: processedBody,
      path: path,
      isAuth: isAuth,
    );
    String responseCode = generateResponse(responseBody, actionName);

    String fileContent = '''
$action

$responseCode
''';

    Directory(outputDir).createSync(recursive: true);
    String filePath = '$outputDir/${actionName.toLowerCase()}_action.dart';
    File(filePath).writeAsStringSync(
        DartFormatter(languageVersion: DartFormatter.latestLanguageVersion).format(fileContent));

    logger.i('Generated $filePath successfully');
  }
}