import 'dart:convert';
import 'dart:io';
import 'package:api_request_generator/api_request_generator.dart';
import 'package:args/command_runner.dart';
import 'package:dart_style/dart_style.dart';

class GenerateActionsFromCollectionCommand extends Command {
  GenerateActionsFromCollectionCommand() {
    argParser.addOption('path',
        abbr: 'p',
        help: 'Path to the Postman collection JSON file',
        mandatory: true);
    argParser.addFlag('only-predefined',
        help: 'Generate actions only from predefined responses',
        defaultsTo: false);
  }

  final logger = Logger();

  @override
  String get description => 'Generate actions and responses from a Postman collection';

  @override
  String get name => 'actions-from-collection';

  @override
  void run() async {
    String collectionPath = argResults!['path'];
    bool onlyPredefined = argResults!['only-predefined'];

    File collectionFile = File(collectionPath);
    if (!collectionFile.existsSync()) {
      logger.e('Error: Collection file not found at $collectionPath');
      exit(1);
    }

    logger.i('Processing collection at $collectionPath...');
    String content = collectionFile.readAsStringSync();
    Map<String, dynamic> collection = jsonDecode(content);

    String baseUrl = collection['variable'].firstWhere(
            (v) => v['key'] == 'base_url' && !v.containsKey('disabled'),
        orElse: () => {'key': 'base_url', 'value': 'https://default.api'})['value'];
    String token = collection['variable']
        .firstWhere((v) => v['key'] == 'token', orElse: () => {'key': 'token', 'value': ''})['value'];


    String baseOutputDir = 'lib/actions';
    Directory(baseOutputDir).createSync(recursive: true);
    await processItems(collection['item'], baseUrl, token, onlyPredefined, baseOutputDir);

    logger.i('DONE!');
  }

  Future<void> processItems(List<dynamic> items, String baseUrl, String token,
      bool onlyPredefined, String outputPath) async {
    for (var item in items) {
      String itemName = item['name'].toLowerCase().replaceAll(' ', '_');
      if (item.containsKey('request')) {
        String endpointName = item['name'];
        var request = item['request'];
        String method = request['method'];
        String url = '$baseUrl/${request['url']['path'].join('/')}';
        List<dynamic> responses = item['response'];

        String authType = 'No Auth';
        if (request.containsKey('auth') && request['auth'] != null) {
          if (request['auth']['type'] == 'bearer') authType = 'Bearer';
        }

        String? responseBody;
        if (responses.isNotEmpty) {
          responseBody = responses[0]['body'];
        } else if (!onlyPredefined) {
          responseBody = await fetchResponse(
            url: url,
            method: method,
            token: authType == 'Bearer' ? token : null,
            body: request['body'],
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
              isAuth: authType == 'Bearer',
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
          }
        } else {
          logger.w('Skipped $endpointName: No response available');
        }
      } else if (item.containsKey('item')) {
        String newOutputPath = '$outputPath/$itemName';
        Directory(newOutputPath).createSync(recursive: true);
        await processItems(item['item'], baseUrl, token, onlyPredefined, newOutputPath);
      }
    }
  }
}