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

  @override
  String get description =>
      'Generate actions and responses from a Postman collection';

  @override
  String get name => 'actions-from-collection';

  @override
  void run() async {
    String collectionPath = argResults!['path'];
    bool onlyPredefined = argResults!['only-predefined'];

    File collectionFile = File(collectionPath);
    if (!collectionFile.existsSync()) {
      print('Error: Collection file not found at $collectionPath');
      exit(1);
    }

    print('Processing collection at $collectionPath...');
    String content = collectionFile.readAsStringSync();
    Map<String, dynamic> collection = jsonDecode(content);

    String baseUrl = collection['variable'].firstWhere(
            (v) => v['key'] == 'base_url' && !v.containsKey('disabled'),
        orElse: () =>
        {'key': 'base_url', 'value': 'https://default.api'})['value'];
    String token = collection['variable'].firstWhere((v) => v['key'] == 'token',
        orElse: () => {'key': 'token', 'value': ''})['value'];
    String locale = collection['variable'].firstWhere(
            (v) => v['key'] == 'locale' && !v.containsKey('disabled'),
        orElse: () => {'key': 'locale', 'value': 'en'})['value'];

    String baseOutputDir = 'lib/actions';
    Directory(baseOutputDir).createSync(recursive: true);
    await processItems(collection['item'], baseUrl, token, locale, onlyPredefined, baseOutputDir);

    print('Actions generated successfully');
  }

  Future<void> processItems(List<dynamic> items, String baseUrl, String token,
      String locale, bool onlyPredefined, String outputPath) async {
    for (var item in items) {
      String itemName = item['name'].toLowerCase().replaceAll(' ', '_');
      // Check if the item is a request
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
            locale: locale,
            body: request['body'],
          );
        }

        if (responseBody != null) {
          try {
            print('Raw responseBody before jsonDecode: $responseBody');
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
                DartFormatter(languageVersion: DartFormatter.latestLanguageVersion)
                    .format(fileContent));
            print('Generated $filePath from $endpointName');
          } catch (e) {
            print('Error parsing response for $endpointName: $e');
            print('Raw responseBody on error: $responseBody');
          }
        } else {
          print('Skipped $endpointName: No response available');
        }
      } else if (item.containsKey('item')) {
        String newOutputPath = '$outputPath/$itemName';
        Directory(newOutputPath).createSync(recursive: true);
        await processItems(item['item'], baseUrl, token, locale, onlyPredefined, newOutputPath);
      }
    }
  }
}