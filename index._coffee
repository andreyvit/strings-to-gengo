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
  "  --langs <langs>   Languages (comma-separated) #var(langs)"
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


class StringsFile

  updateStatistics: ->
    @wordCount = (e.wordCount for e in @entries).reduce(((a, b) -> a + b), 0)
    @entryCount = @entries.length


class TranslatableFile extends StringsFile

  updateStatistics: ->
    super()
    @unmatchedEntryCount = @entries.filter((e) -> !e.baseEntry).length
    @previouslyTranslatedEntryCount = @entries.filter((e) -> e.isPreviouslyTranslated()).length
    @gengoTranslatedEntryCount = @entries.filter((e) -> e.isGengoTranslated()).length
    @gengoNewlyTranslatedEntryCount = @entries.filter((e) -> e.isNewlyTranslated()).length
    @gengoRetranslatedEntryCount = @entries.filter((e) -> e.isRetranslated()).length
    @gengoModifiedEntryCount = @entries.filter((e) -> e.isModified()).length
    @gengoMatchedEntryCount = @entries.filter((e) -> e.isGengoMatched()).length
    @translatedEntryCount = @entries.filter((e) -> e.isTranslated()).length
    @untranslatedEntryCount = @entries.filter((e) -> !e.isTranslated()).length


class AndroidXmlFile extends TranslatableFile
  constructor: (@path) ->
    @name = Path.basename(@path)
    @entries = []
    @entriesByKey = {}
    @terms = []

  read: (_) ->
    body = fs.readFile(@path, 'utf8', _)
    result = xml2js.parseString(body, {explicitArray: yes}, _)

    fs.writeFileSync(Path.basename(@path) + '.txt', JSON.stringify(result, null, 2))

    for el in result?.resources?.string ? []
      key = el.$.name?.trim()
      value = el._?.trim()
      if key and value
        @entries.push(new TranslatableEntry(this, key, value))
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
        console.error "\n  Tag found in key '%s'\n  Original: %s\n  English: %s\n  Translated: %s\n", key, body, entry.shortValue, replacement
        return match

      # console.log "  %s: %j => %j", key, body, replacement
      return prefix + replacement + suffix

    outputDir = Path.dirname(localizedPath)
    if !existsAsync(outputDir, _)
      fs.mkdir(outputDir, _)

    fs.writeFile(localizedPath, body, _)


stringsEscape = (string) ->
  string = string.replace(/(["\\])/g, '\\$1')
  string = string.replace(/\n/g, '\\n')
  return string

stringsUnescape = (string) ->
  string = string.replace(/\\(["\\])/g, '$1')
  string = string.replace(/\\n/g, '\n')
  return string


class iOSStringsFileCluster
  constructor: (basePath, languages) ->
    @name = Path.basename(basePath)

    @baseFile = new iOSStringsFile(this, basePath, 'en')
    @localizedFiles = []
    @localizedFilesByLang = {}
    @files = [@baseFile]

    basedir = Path.dirname(Path.dirname(basePath))
    for lang in languages
      path = Path.join(basedir, "#{lang}.lproj", @name)
      file = new iOSStringsFile(this, path, lang)
      @localizedFilesByLang[lang] = file
      @localizedFiles.push(file)
      @files.push(file)

  lookupEntry: (key, lang) ->
    @localizedFilesByLang[lang].lookupEntry(key)


class iOSStringsFile extends TranslatableFile
  constructor: (@cluster, @path, @lang) ->
    @name = Path.basename(@path)
    @entries = []
    @entriesByKey = {}
    @terms = []
    @exists = fs.existsSync(@path)

  read: (_) ->
    return unless @exists

    body = fs.readFile(@path, 'utf8', _)

    unmatchedBody = body.replace IOS_STRINGS_REGEXP, (fullMatch, comments, key, value) =>
      lastComment = ''
      unmatchedComments = comments.replace IOS_COMMENT_REGEXP, (fullComment, comment) =>
        lastComment = comment
        return ''
      if unmatchedComments.trim().length > 0
        throw new Error "Failed to parse comments; unparsed portion is:\n---\n#{unmatchedComments}\n---"

      @_addEntry(new TranslatableEntry(this, stringsUnescape(key), stringsUnescape(value), lastComment))
      return ''

    if unmatchedBody.trim().length > 0
      throw new Error "Failed to parse file; unparsed portion is:\n---\n#{unmatchedBody}\n---"

    undefined


  _addEntry: (entry) ->
    @entries.push(entry)
    @entriesByKey[entry.key] = entry

  lookupEntry: (key) ->
    unless @entriesByKey.hasOwnProperty(key)
      @_addEntry(new TranslatableEntry(this, key, ''))
    return @entriesByKey[key]


  writeLocalized: (localizedPath, _) ->
    entriesByKey = {}
    for entry in @entries
      entriesByKey[entry.key] = entry

    strings = []
    for entry in @entries when entry.translatedString
      escaped = stringsEscape(entry.translatedString)

      strings.push "\"#{stringsEscape(entry.key)}\" = \"#{escaped}\";\n"

    body = strings.join('')

    outputDir = Path.dirname(localizedPath)
    if !existsAsync(outputDir, _)
      fs.mkdir(outputDir, _)

    fs.writeFile(localizedPath, body, _)


class StringEntry
  constructor: (@file, @key, @value, @comment='') ->
    @value = @value.replace(/\\'/g, "'")
    @value = @value.replace(/\\n\n/g, "\n")
    @value = @value.replace(/\\n\\n\n\n/g, "\n\n")
    @value = @value.replace(/\\n/g, "\n")

    @shortValue = @value.replace(/\n/g, "  ")

    @wordCount = @value.split(/\s+/).length

  _initialize: ->
    @baseEntry = null

  lookupEntryIn: (lang) ->
    @file.cluster.lookupEntry(@key, lang)

class TranslatableEntry extends StringEntry
  _initialize: ->
    @gengoEntry = null

  isGengoTranslated: -> !!@gengoEntry
  isPreviouslyTranslated: -> !!@value
  isNewlyTranslated: -> @isGengoTranslated() && !@isPreviouslyTranslated()
  isRetranslated: -> @isGengoTranslated() && @isPreviouslyTranslated() && (@gengoEntry.value != @value)
  isGengoMatched: -> @isGengoTranslated() && @isPreviouslyTranslated() && (@gengoEntry.value == @value)
  isModified: -> @isNewlyTranslated() || @isRetranslated()

  getTranslatedEntry: -> @gengoEntry or (@value && this) or null
  isTranslated: -> !!@getTranslatedEntry()

class GengoEntry extends StringEntry
  _initialize: ->
    @translatedEntry = null


class GengoFileCluster
  constructor: (template, languages) ->
    @filesByLang = {}
    @files = []
    @exists = fs.existsSync(@path)

    for lang in languages
      path = template.replace(/XX/g, lang)
      file = new IncomingGengoFile(path, lang)
      @filesByLang[lang] = file
      @files.push(file)


class IncomingGengoFile extends StringsFile
  constructor: (@path, @lang) ->
    @name = Path.basename(@path)
    @entries = []
    @exists = fs.existsSync(@path)
    @outgoingFile = new OutgoingGengoFile(@path.replace(/\.txt$/, '-job.txt'), @lang)


  updateStatistics: ->
    super()
    @matchedEntryCount = @entries.filter((e) -> !!e.translatedEntry).length
    @unmatchedEntryCount = @entries.filter((e) -> !e.translatedEntry).length


  read: (_) ->
    return unless @exists

    body = fs.readFile(@path, 'utf8', _)

    body = body.replace ///  \[\[\[  [^⇆]*?  \]\]\]  ///g, (str) =>
      if str.match ///^  \[\[\[  \s*  English: \s (.*) \s \]\]\]  $///i
        str
      else
        ''

    lines = body.split("\n")

    curEntry = null
    translatedEntries = []
    for line in lines
      trimmed = line.trim()
      continue if trimmed == ''

      translationSeen = no
      if m = trimmed.match ///^  \[\[\[  \s*  key \s* : \s*  ([a-z0-9_$]+)  \s*  \]\]\]  $///i
        translatedEntries.push(curEntry) if curEntry
        curEntry = { key: m[1], lines: [] }
        translationSeen = no
      else if m = trimmed.match ///^  \[\[\[  \s*  English: \s (.*) \s \]\]\]  $///i
        translatedEntries.push(curEntry) if curEntry
        curEntry = { key: m[1], lines: [] }
        translationSeen = no
      else if m = trimmed.match ///^  \[\[\[  .*  \]\]\]  $///
        if curEntry and translationSeen
          translatedEntries.push(curEntry)
          curEntry = null
          translationSeen = no
      else if curEntry
        translationSeen = yes
        curEntry.lines.push(line)
    translatedEntries.push(curEntry) if curEntry

    for entry in translatedEntries
      key = stringsUnescape(entry.key)  # TODO: only in iOS!
      translatedString = stringsUnescape(entry.lines.join("\n").trim())
      @entries.push(new GengoEntry(this, key, translatedString))

    return


class OutgoingGengoFile extends StringsFile
  constructor: (@path, @lang) ->
    @name = Path.basename(@path)
    @entries = null

  write: (_) ->
    # filter = ///#{options.vocabularyFilter}///i

    allEntryLines =
      for entry in @entries
        "[[[ key: #{entry.key} ]]]\n[[[ English: #{entry.shortValue} ]]]\n#{entry.value}"

    # # vocabTerms = []
    # # vocabHash = {}

    # # for term in @terms
    # #   if !!term[lang] and term.source.match(filter)
    # #     vocabTerms.push(term) unless vocabHash.hasOwnProperty(term.en)
    # #     vocabHash[term.en] = term[lang]

    vocabLines = []
    # for term in vocabTerms
    #   line = "• <en> — <xx>".replace('<en>', term.en).replace('<xx>', vocabHash[term.en])
    #   vocabLines.push(line)
    #   console.log "  %s", line

    text = [PREFIX].concat(allEntryLines).join("\n\n") + "\n"
    text = text.replace('<vocab>', vocabLines.join("\n"))
    fs.writeFile(@path, text, _)


class Processor
  constructor: (@options, @langs) ->
    @localizableFileClusters = []
    @gengoCluster = null
    @terms = []
    @vocabularyFilter = null

  addStringsFileCluster: (file) ->
    @localizableFileClusters.push(file)

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


  loadStringsFiles: (_) ->
    console.log("\nLoading localization files")
    for cluster in @localizableFileClusters
      for file in cluster.files
        console.log("  %s (%s)", file.name, file.lang)
        file.read(_)
        file.updateStatistics()
        console.log("    %d words in %d entries", file.wordCount, file.entryCount)


  loadGengoFiles: (_) ->
    console.log("\nLoading Gengo files")
    for file in @gengoCluster.files
      console.log("  %s (%s)", file.name, file.lang)
      file.read(_)
      file.updateStatistics()
      console.log("    %d words in %d entries", file.wordCount, file.entryCount)


  matchStrings: () ->
    console.log("\nMatching localizable strings to translations")

    baseEntries = []
    baseEntriesByKey = {}
    for cluster in @localizableFileClusters
      for entry in cluster.baseFile.entries
        baseEntries.push(entry)
        baseEntriesByKey[entry.key] = entry

    for cluster in @localizableFileClusters
      for file in cluster.localizedFiles
        for entry in file.entries
          if baseEntriesByKey.hasOwnProperty(entry.key)
            entry.baseEntry = baseEntriesByKey[entry.key]

    for gengoFile in @gengoCluster.files
      for gengoEntry in gengoFile.entries
        if baseEntriesByKey.hasOwnProperty(gengoEntry.key)
          baseEntry = baseEntriesByKey[gengoEntry.key]
          translatedEntry = baseEntry.lookupEntryIn(gengoFile.lang)

          gengoEntry.baseEntry = baseEntry
          gengoEntry.translatedEntry = translatedEntry
          translatedEntry.gengoEntry = gengoEntry

    @untranslatedEntriesByLang = {}

    for lang in @langs
      console.log("  %s", lang)

      gengoFile = @gengoCluster.filesByLang[lang]
      gengoFile.updateStatistics()
      console.log("    Gengo: %d matched, %d unmatched", gengoFile.matchedEntryCount, gengoFile.unmatchedEntryCount)

      for cluster in @localizableFileClusters
        file = cluster.localizedFilesByLang[lang]
        file.updateStatistics()
        console.log("    %s", file.name)
        console.log("      previously translated: %d total, %d no longer relevant, %d retranslated", file.previouslyTranslatedEntryCount, file.unmatchedEntryCount, file.gengoRetranslatedEntryCount)
        console.log("      Gengo: %d incoming, of those %d new, %d changed, %d same", file.gengoTranslatedEntryCount, file.gengoNewlyTranslatedEntryCount, file.gengoRetranslatedEntryCount, file.gengoMatchedEntryCount)
        console.log("      now: %d translated, %d untranslated", file.translatedEntryCount, file.untranslatedEntryCount)

      untranslatedEntries = []
      for baseEntry in baseEntries
        translatableEntry = baseEntry.lookupEntryIn(lang)
        unless translatableEntry.isTranslated()
          untranslatedEntries.push(baseEntry)

      console.log("    %d untranslated entries", untranslatedEntries.length)

      @untranslatedEntriesByLang[lang] = untranslatedEntries


  exportStringsInLanguages: (template, langs, options, _) ->
    console.log("\nWriting Gengo files")
    for lang in langs
      console.log("  %s", lang)

      gengoFile = @gengoCluster.filesByLang[lang]
      outgoingFile = gengoFile.outgoingFile
      outgoingFile.entries = @untranslatedEntriesByLang[lang]
      console.log("    %s - %d entries", outgoingFile.name, outgoingFile.entries.length)
      outgoingFile.write(_)

  importStrings: (file, lang, options, _) ->
    console.log("importStrings %s", lang)
    console.log("importStrings @localizableFileClusters = %s", @localizableFileClusters.length)
    for file in @localizableFileClusters
      localizedPath = file.localizedPath(lang)
      console.log("Writing %s", localizedPath)
      file.writeLocalized(localizedPath, _)

  importStringsInLanguages: (template, langs, options, _) ->
    for lang in langs
      console.log("%s:", lang)
      file = template.replace(/XX/g, lang)
      @importStrings(file, lang, options, _)

  loadTranslatedStringsInLanguages: (template, langs, options, _) ->
    console.log("\nLoading Gengo files")
    for lang in langs
      file = template.replace(/XX/g, lang)
      console.log("  %s (%s)", Path.basename(file), lang)
      @loadTranslatedStrings(file, lang, options, _)


run = (_) ->
  options = require('dreamopt')(USAGE)
  console.log "options = %j", options

  langs = options.langs.split(',')

  processor = new Processor(options, langs)
  # for file in options.androidXmlFiles or []
  #   processor.addStringsFileCluster(new AndroidXmlFile(file))
  for file in options.iosStringsFiles or []
    processor.addStringsFileCluster(new iOSStringsFileCluster(file, langs))

  processor.gengoCluster = new GengoFileCluster(options.textFileTemplate, langs)

  if options.vocabularyCsvFile
    processor.loadVocabularyFile(options.vocabularyCsvFile, _)

  processor.loadStringsFiles(_)
  processor.loadGengoFiles(_)
  processor.matchStrings()

  if options.export
    processor.exportStringsInLanguages(options.textFileTemplate, langs, options, _)
  else if options.import
    processor.importStringsInLanguages(options.textFileTemplate, langs, options, _)

run (err) ->
  throw err if err

