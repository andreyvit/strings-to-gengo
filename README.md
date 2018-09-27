
[![Greenkeeper badge](https://badges.greenkeeper.io/andreyvit/strings-to-gengo.svg)](https://greenkeeper.io/)

Example:

    _coffee index._coffee --text ~/somewhere/gengo/gengo-XX.txt --ios-strings ~/dev/myapp/Localization/en.lproj/Localizable.strings --langs es,fr,it,de,pt --import

Options:

* `--text ~/somewhere/gengo/gengo-XX.txt` — location of Gengo files; XX will be replaced by language name; '-job' will be appended for outgoing files, so e.g. gengo-fr-job.txt is a French strings to submit to Gengo, and gengo-fr.txt is where you should save the translation provided by Gengo

* `--ios-strings ~/dev/myapp/Localization/en.lproj/Localizable.strings` — location of the base localization file(s)

* `--langs es,fr,it,de,pt` — comma-separated list of languages to process

* `--export` — use this option to export missing strings into Gengo job files

* `--import` — use this option to import translations from Gengo txt files into strings files

Run without `--import` and `--export` to preview the results.
