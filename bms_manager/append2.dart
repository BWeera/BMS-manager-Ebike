import 'dart:io';

void main() {
  final file = File('lib/main.dart');
  var text = file.readAsStringSync();
  
  // need original text to extract the end bit
  // But wait, the file is already overwritten from start to newUi! I don't have the end bit!
  // I need to git checkout or I need to fetch the BmsMetrics and BmsDecoder!
}
