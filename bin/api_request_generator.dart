import 'package:api_request_generator/api_request_generator.dart';
import 'package:api_request_generator/src/generate_action_command.dart';
import 'package:api_request_generator/src/generate_single_action_command.dart';
import 'package:args/command_runner.dart';

void main(List<String> arguments) {
  final runner = CommandRunner('tool', 'A command line tool')
    ..addCommand(GenerateActionsFromCollectionCommand())
    ..addCommand(GenerateSingleActionCommand());

  runner.run(arguments).catchError((error) {
    print('${ColorsText.red}Error: $error${ColorsText.reset}');
  });
}
