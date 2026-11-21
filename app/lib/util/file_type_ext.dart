import 'package:flutter/cupertino.dart';
import 'package:localsend_isolates/model/file_type.dart';

extension FileTypeExt on FileType {
  IconData get icon {
    return switch (this) {
      FileType.image => CupertinoIcons.photo_fill,
      FileType.video => CupertinoIcons.film_fill,
      FileType.pdf => CupertinoIcons.doc_text_fill,
      FileType.text => CupertinoIcons.doc_plaintext,
      FileType.apk => CupertinoIcons.cube_box_fill,
      FileType.other => CupertinoIcons.doc_fill,
    };
  }
}
