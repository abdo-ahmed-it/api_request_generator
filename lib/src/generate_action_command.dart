import 'dart:convert';
import 'dart:io';
import 'package:api_request_generator/api_request_generator.dart';
import 'package:args/command_runner.dart';
import 'package:dart_style/dart_style.dart';

class GenerateActionsFromCollectionCommand extends Command {
  GenerateActionsFromCollectionCommand() {
    argParser.addOption('config',
        abbr: 'c',
        help: 'Path to the config.json file',
        defaultsTo: 'config.json');
  }

  final logger = Logger();

  @override
  String get description => 'Generate actions and responses from a Postman collection using a config file';

  @override
  String get name => 'actions-from-collection';

  @override
  void run() async {
    String configPath = argResults!['config'];
    File configFile = File(configPath);

    if (!configFile.existsSync()) {
      logger.e('Error: Config file not found at $configPath');
      exit(1);
    }

    logger.i('Reading config from $configPath...');
    String configContent = configFile.readAsStringSync();
    Map<String, dynamic> config;
    try {
      config = jsonDecode(configContent);
    } catch (e) {
      logger.e('Error parsing config.json', error: e);
      exit(1);
    }

    String baseUrl = config['base_url'];
    String? token = config['token'];
    String collectionPath = config['collection_path'] ?? 'lib/api/postman_collection.json';
    String outputDir = config['output_dir'] ?? 'lib/actions';
    List<String> excludedEndpoints = (config['excluded_endpoints'] as List<dynamic>?)?.cast<String>() ?? [];
    List<String> includedEndpoints = (config['included_endpoints'] as List<dynamic>?)?.cast<String>() ?? [];

    logger.i('Config loaded: base_url=$baseUrl, token=$token, collection_path=$collectionPath');
    if (excludedEndpoints.isNotEmpty) {
      logger.i('Excluded endpoints: ${excludedEndpoints.join(', ')}');
    }
    if (includedEndpoints.isNotEmpty) {
      logger.i('Included endpoints: ${includedEndpoints.join(', ')}');
    }

    File collectionFile = File(collectionPath);
    if (!collectionFile.existsSync()) {
      logger.e('Error: Collection file not found at $collectionPath');
      exit(1);
    }

    logger.i('Processing collection at $collectionPath...');
    String content = collectionFile.readAsStringSync();
    Map<String, dynamic> collection = jsonDecode(content);

    Directory(outputDir).createSync(recursive: true);
    int excludedCount = await processItems(collection['item'], baseUrl, token, outputDir, excludedEndpoints, includedEndpoints);

    logger.i('Actions generated successfully in $outputDir');
    logger.i('Total excluded endpoints: $excludedCount');
  }

  Future<int> processItems(
      List<dynamic> items,
      String baseUrl,
      String? token,
      String outputPath,
      List<String> excludedEndpoints,
      List<String> includedEndpoints) async {
    int excludedCount = 0;

    for (var item in items) {
      String itemName = item['name'].toLowerCase().replaceAll(' ', '_');
      if (item.containsKey('request')) {
        String endpointName = item['name'];
        var request = item['request'];
        String method = request['method'];
        String path = '/${request['url']['path'].join('/')}';
        String url = '$baseUrl$path';
        List<dynamic> responses = item['response'];

        String normalizedPath = path.startsWith('/') ? path.substring(1) : path;

        if (includedEndpoints.isNotEmpty &&
            !includedEndpoints.any((included) => included == path || included == normalizedPath)) {
          logger.w('Skipped $endpointName: Endpoint $path is not in included_endpoints');
          continue;
        }

        if (excludedEndpoints.any((excluded) => excluded == path || excluded == normalizedPath)) {
          logger.w('Skipped $endpointName: Endpoint $path is in excluded_endpoints');
          excludedCount++;
          continue;
        }

        String authType = 'noauth';
        if (request.containsKey('auth') && request['auth'] != null) {
          authType = request['auth']['type'];
        }

        String? responseBody;
        if (responses.isNotEmpty) {
          responseBody = responses[0]['body'];
        } else {
          responseBody = await fetchResponse(
            url: url,
            method: method,
            token: authType != 'noauth' ? token : null,
            body: request['body'],
            authType: authType,
          );
        }

        if (responseBody != null) {
          try {
            String modelName = endpointName.replaceAll(' ', '');
            String action = generateAction(
              name: modelName,
              method: method,
              body: request['body'],
              path: request['url']['path'].join('/'),
              isAuth: authType != 'noauth',
            );
            String responseCode = generateResponse(responseBody, modelName);

            String fileContent = '''
$action

$responseCode
''';
            String filePath = '$outputPath/${itemName.toLowerCase().replaceAll(' ', '_')}_action.dart';
            File(filePath).writeAsStringSync(
                DartFormatter(languageVersion: DartFormatter.latestLanguageVersion).format(fileContent));
            logger.i('Generated $filePath from $endpointName');
          } catch (e) {
            logger.e('Error parsing response for $endpointName', error: e);
            logger.d('Raw responseBody on error: $responseBody');
          }
        } else {
          logger.w('Skipped $endpointName: No response available');
        }
      } else if (item.containsKey('item')) {
        String newOutputPath = '$outputPath/$itemName';
        Directory(newOutputPath).createSync(recursive: true);
        excludedCount += await processItems(
            item['item'], baseUrl, token, newOutputPath, excludedEndpoints, includedEndpoints);
      }
    }
    return excludedCount;
  }
}