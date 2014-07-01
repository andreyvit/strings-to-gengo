#!/usr/bin/env _coffee

Path   = require 'path'
fs     = require 'fs'
xml2js = require 'xml2js'
csv    = require 'csv'


existsAsync = (path, callback) ->
  fs.exists(path, (result) -> callback(null, result))


USAGE = [
  "Usage: strings-to-gengo --export strings.txt strings.xml"

  "Options:"
  "  --export  Export data"
  "  --import  Import data"
  "  --text <file-XX.txt>  Gengo text file #required #var(textFileTemplate)"
  "  --android-xml <strings.xml>  Android xml resource file with strings #list #var(androidXmlFiles)"
  "  --ios-strings <localization.strings>  Android xml resource file with strings #list #var(iosStringsFiles)"
  "  --vocabulary <vocabulary.csv>  Common vocabulary file exported from Google Docs #var(vocabularyCsvFile)"
  "  --vocabulary-filter <regexp>  Regular expression to filter by the 'source' column of the vocabulary #var(vocabularyFilter)"
  "  --lang <lang>   Add this language #list #var(langs)"
  "  --keys <keys>   A comma-separated list of keys to process"
]

PREFIX = """
[[[ IMPORTANT: The results of this translation will be processed automatically. ]]]
[[[ IMPORTANT: Please translate entries inline, keeping the comments. ]]]
[[[ IMPORTANT: Please don't reorder or remove entries. ]]]

[[[ NOTE: You're translating user inferface strings for an Android app. ]]]
[[[ NOTE: Sometimes, key names will give you a hint about where the strings are used. ]]]

[[[ IMPORTANT: Please keep the capitalization of the original string, unless you have good reasons to do otherwise. ]]]

[[[ IMPORTANT: Please don't translate our brand names (Ascendo, VidaLingua, VidaLingua Dictionary, Dictionary+). ]]]

[[[ IMPORTANT: Some strings contain substitution keys like {DATE}, {X} or %2$d — please keep them intact, but put them in the proper place. ]]]

[[[
IMPORTANT: Please use the following standard translations of common Android terms (but adjust them according to the context):

<vocab>

]]]
"""

IOS_STRINGS_REGEXP = ///
  (                          # group 1: comments
    (?:
      /\* [^⇆]*? \*/              #   one comment
      \s*
    )*
  )
  "([^⇆]*?)"                    # group 2: key
  \s* = \s*
  "([^⇆]*?)"                    # group 3: value
  \s* ;
///g

IOS_COMMENT_REGEXP = ///
  /\* ([^⇆]*?) \*/
///g

class AndroidXmlFile
  constructor: (@path) ->
    @name = Path.basename(@path)
    @entries = []
    @terms = []

  read: (_) ->
    body = fs.readFile(@path, 'utf8', _)
    result = xml2js.parseString(body, {explicitArray: yes}, _)

    fs.writeFileSync(Path.basename(@path) + '.txt', JSON.stringify(result, null, 2))

    for el in result?.resources?.string ? []
      key = el.$.name?.trim()
      origValue = el._?.trim()
      if key and origValue
        @entries.push(new StringEntry(this, key, origValue))
      else
        console.error("Skipped entry for key #{key}")

  localizedPath: (lang) ->
    @path.replace(/// /values/ ///, "/values-#{lang}/")

  writeLocalized: (localizedPath, _) ->
    entriesByKey = {}
    for entry in @entries
      entriesByKey[entry.key] = entry

    body = fs.readFile(@path, 'utf8', _)

    body = body.replace /// (<string([^>]+)>)(.*?)(</string>) ///g, (match, prefix, attrs, body, suffix) ->
      unless m = attrs.match /// name="([a-z0-9_$]+)" ///i
        console.error "  Cannot parse %j", match
        return match

      key = m[1]

      unless entry = entriesByKey[key]
        console.error "  No entry found for '%s': %s", key, body
        return match

      unless entry.translatedString
        console.error "  No translation found for '%s': %s", key, body
        return match

      replacement = entry.translatedString
      replacement = replacement.replace(/\n/g, "\\n")
      replacement = replacement.replace(/'/g, "\\'")

      if body.match /</
        console.error "\n  Tag found in key '%s'\n  Original: %s\n  English: %s\n  Translated: %s\n", key, body, entry.shortOrigValue, replacement
        return match

      # console.log "  %s: %j => %j", key, body, replacement
      return prefix + replacement + suffix

    outputDir = Path.dirname(localizedPath)
    if !existsAsync(outputDir, _)
      fs.mkdir(outputDir, _)

    fs.writeFile(localizedPath, body, _)


class iOSStringsFile
  constructor: (@path) ->
    @name = Path.basename(@path)
    @entries = []
    @terms = []

  read: (_) ->
    body = fs.readFile(@path, 'utf8', _)

    unmatchedBody = body.replace IOS_STRINGS_REGEXP, (fullMatch, comments, key, value) =>
      lastComment = ''
      unmatchedComments = comments.replace IOS_COMMENT_REGEXP, (fullComment, comment) =>
        lastComment = comment
        return ''
      if unmatchedComments.trim().length > 0
        throw new Error "Failed to parse comments; unparsed portion is:\n---\n#{unmatchedComments}\n---"

      @entries.push(new StringEntry(this, key, value, lastComment))
      return ''

    if unmatchedBody.trim().length > 0
      throw new Error "Failed to parse file; unparsed portion is:\n---\n#{unmatchedBody}\n---"

    undefined

  localizedPath: (lang) ->
    @path.replace(/// /en.lproj/ ///, "/#{lang}.lproj/")

  writeLocalized: (localizedPath, _) ->
    entriesByKey = {}
    for entry in @entries
      entriesByKey[entry.key] = entry

    strings = []
    for entry in @entries
      strings.push "\"#{entry.key}\" = \"#{entry.translatedString}\";\n"

    body = strings.join('')

    outputDir = Path.dirname(localizedPath)
    if !existsAsync(outputDir, _)
      fs.mkdir(outputDir, _)

    fs.writeFile(localizedPath, body, _)



class StringEntry
  constructor: (@file, @key, @origValue, @comment='') ->
    @origValue = @origValue.replace(/\\'/g, "'")
    @origValue = @origValue.replace(/\\n\n/g, "\n")
    @origValue = @origValue.replace(/\\n\\n\n\n/g, "\n\n")
    @origValue = @origValue.replace(/\\n/g, "\n")

    @shortOrigValue = @origValue.replace(/\n/g, "  ")

    @wordCount = @origValue.split(/\s+/).length


class Processor
  constructor: (@options) ->
    @files = []
    @terms = []
    @vocabularyFilter = null

  addStringsFile: (file) ->
    @files.push(file)

  loadVocabularyFile: (filePath, callback) ->
    data = fs.readFileSync(filePath, 'utf8')

    headers = null
    csv()
      .from(data)
      .on 'record', (row, index) =>
        if index == 0
          headers = row
        else if (row.length == headers.length) and row[0]
          rec = {}
          for cell, colIndex in row
            rec[headers[colIndex]] = cell
          if !!rec.en
            @addTerm(rec)
      .on 'end', =>
        callback(null)

  addTerm: (rec) ->
    @terms.push(rec)

  loadAppFiles: (_) ->
    for file in @files
      console.log("Loading %s", file.path)
      file.read(_)
      file.wordCount = (e.wordCount for e in file.entries).reduce(((a, b) -> a + b), 0)

    report = {}
    for file in @files
      report[file.name] = {
        entryCount: file.entries.length
        wordCount:  file.wordCount
      }
    report.wordCount = (f.wordCount for f in @files).reduce(((a, b) -> a + b), 0)
    console.log "report = " + JSON.stringify(report, null, 2)

  exportStrings: (file, lang, options, _) ->
    filter = ///#{options.vocabularyFilter}///i

    allEntries = (f.entries for f in @files).reduce(((a, b) -> a.concat(b)), [])

    if options.keys
      keys = options.keys.split(',')
      allEntries = (entry for entry in allEntries when entry.key in keys)

    allEntryLines =
      for entry in allEntries
        "[[[ key: #{entry.key} ]]]\n[[[ English: #{entry.shortOrigValue} ]]]\n#{entry.origValue}"

    vocabTerms = []
    vocabHash = {}

    for term in @terms
      if !!term[lang] and term.source.match(filter)
        vocabTerms.push(term) unless vocabHash.hasOwnProperty(term.en)
        vocabHash[term.en] = term[lang]

    vocabLines = []
    for term in vocabTerms
      line = "• <en> — <xx>".replace('<en>', term.en).replace('<xx>', vocabHash[term.en])
      vocabLines.push(line)
      console.log "  %s", line

    text = [PREFIX].concat(allEntryLines).join("\n\n") + "\n"
    text = text.replace('<vocab>', vocabLines.join("\n"))
    fs.writeFile(file, text, _)
    console.log("  %s saved.", file)

  exportStringsInLanguages: (template, langs, options, _) ->
    for lang in langs
      console.log("%s:", lang)
      file = template.replace(/XX/g, lang)
      @exportStrings(file, lang, options, _)

  loadTranslatedStrings: (file, lang, options, _) ->
    origEntries = (f.entries for f in @files).reduce(((a, b) -> a.concat(b)), [])

    origEntriesByKey = {}
    for entry in origEntries
      origEntriesByKey[entry.key] = entry

    console.log("  Loading %s", file)
    lines = fs.readFile(file, 'utf8', _).split("\n")

    curEntry = null
    translatedEntries = []
    for line in lines
      trimmed = line.trim()
      continue if trimmed == ''

      if m = trimmed.match ///^  \[\[\[  \s*  key \s* : \s*  ([a-z0-9_$]+)  \s*  \]\]\]  $///i
        translatedEntries.push(curEntry) if curEntry
        curEntry = { key: m[1], lines: [] }
      else if m = trimmed.match ///^  \[\[\[  \s*  English: \s (.*) \s \]\]\]  $///i
        translatedEntries.push(curEntry) if curEntry
        curEntry = { key: m[1], lines: [] }
      else if m = trimmed.match ///^  \[\[\[  .*  \]\]\]  $///
        #
      else if curEntry
        curEntry.lines.push(line)
    translatedEntries.push(curEntry) if curEntry

    for entry in translatedEntries
      entry.translatedString = entry.lines.join("\n").trim()

    for translatedEntry in translatedEntries
      if origEntry = origEntriesByKey[translatedEntry.key]
        origEntry.translatedString = translatedEntry.translatedString
      else
        console.error("  Unknown translated key in #{lang}: %j", translatedEntry.key)

    for origEntry in origEntries
      if !origEntry.translatedString
        console.error("  Left untranslated to #{lang}: %j", origEntry.key)

    console.log("  Done loading %s", file)

  importStrings: (file, lang, options, _) ->
    @loadTranslatedStrings(file, lang, options, _)
    console.log("importStrings %s", lang)
    console.log("importStrings @files = %s", @files.length)
    for file in @files
      localizedPath = file.localizedPath(lang)
      console.log("Writing %s", localizedPath)
      file.writeLocalized(localizedPath, _)

  importStringsInLanguages: (template, langs, options, _) ->
    for lang in langs
      console.log("%s:", lang)
      file = template.replace(/XX/g, lang)
      @importStrings(file, lang, options, _)


run = (_) ->
  options = require('dreamopt')(USAGE)
  console.log "options = %j", options

  processor = new Processor(options)
  for file in options.androidXmlFiles or []
    processor.addStringsFile(new AndroidXmlFile(file))
  for file in options.iosStringsFiles or []
    processor.addStringsFile(new iOSStringsFile(file))

  if options.vocabularyCsvFile
    processor.loadVocabularyFile(options.vocabularyCsvFile, _)

  processor.loadAppFiles(_)

  if options.export
    processor.exportStringsInLanguages(options.textFileTemplate, options.langs, options, _)
  else if options.import
    processor.importStringsInLanguages(options.textFileTemplate, options.langs, options, _)

run (err) ->
  throw err if err

