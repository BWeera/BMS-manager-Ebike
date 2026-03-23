import 'dart:io';

void main() {
  final file = File('lib/main.dart');
  var text = file.readAsStringSync();

  final startMarker = '  @override\r\n  Widget build(BuildContext context) {\r\n    return Scaffold(';
  final backupStartMarker = '  @override\n  Widget build(BuildContext context) {\n    return Scaffold(';
  
  final endMarker = 'class BmsMetrics {\r\n';
  final backupEndMarker = 'class BmsMetrics {\n';

  var startIdx = text.indexOf(startMarker);
  if (startIdx == -1) startIdx = text.indexOf(backupStartMarker);
  
  var endIdx = text.indexOf(endMarker);
  if (endIdx == -1) endIdx = text.indexOf(backupEndMarker);

  if (startIdx != -1 && endIdx != -1) {
    file.writeAsStringSync(text.substring(0, startIdx));
    print('Ready for part 2');
  }
}
