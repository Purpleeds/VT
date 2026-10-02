# Splitter models

Put `VocalSeparator.mlpackage` here (made by `tools/convert_separator.py` or the
"Convert separation model" GitHub workflow). The build workflow compiles it and
bundles it, which turns on the High Quality vocal splitter. Without it the app
uses the Basic engine.

Optional: `VocalSeparatorBest.mlpackage`, a second model used for Best quality.
