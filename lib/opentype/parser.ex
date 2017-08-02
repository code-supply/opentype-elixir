defmodule OpenType.Parser do
  @moduledoc false
  use Bitwise, only_operators: true
  require Logger

  # extract the TTF (or TTC) version
  def extractVersion(ttf, <<version :: size(32), data :: binary>>) do
    {%{ttf | :version => version}, data}
  end

  # read in the font header
  def readHeader({%{version: v}=ttf, data}, _full) when v in [0x00010000, 0x74727565, 0x4F54544F] do
    <<numTables::16,
    _searchRange::16,
    _entrySelector::16,
    _rangeShift::16,
    remainder::binary>> = data
    tables = readTables(remainder, numTables)
    isCFF = Enum.any?(tables, fn(x) -> x.name == "CFF " end)
    %{ttf | :tables => tables, :isCFF => isCFF}
  end
  def readHeader({%{version: 0x74727566}=ttf, data}, full_data) do
    #TODO: read in TTC header info, subfont 0
    <<_ttcVersion::32,
    numSubfonts::32, rem::binary>> = data
    #read in 32-bit subfont offsets
    {offsets, _remaining} = readOffset([], rem, numSubfonts)
    subfont = subtable(full_data, offsets[0])
    <<_ttfVersion::32, numTables::16,
    _searchRange::16,
    _entrySelector :: size(16),
    _rangeShift :: size(16),
    remainder :: binary>> = subfont
    #IO.puts "Subfont 0 has #{numTables} tables"
    tables = readTables(remainder, numTables)
    isCFF = Enum.any?(tables, fn(x) -> x.name == "CFF " end)
    %{ttf | :tables => tables, :isCFF => isCFF}
  end
  def readHeader({ttf, _data}, _) do
    Logger.error("Unknown font format version")
    ttf
  end

  # raw data for a given table
  def rawTable(ttf, name, data) do
    t = Enum.find(ttf.tables, fn(x) -> x.name == name end)
    cond do
      t -> binary_part(data, t.offset, t.length)
      true -> nil
    end
  end

  # lookup a table by name
  def lookupTable(ttf, name) do
    t = Enum.find(ttf.tables, fn(x) -> x.name == name end)
    cond do
      t -> {t.offset, t.length}
      true -> nil
    end
  end

  # is there a particular font table?
  def hasTable?(ttf, name) do
    Enum.any?(ttf.tables, fn(x) -> x.name == name end)
  end

  # use this when the length of the actual subtable is unknown
  def subtable(table, offset) do
    binary_part(table, offset, byte_size(table) - offset)
  end

  # read in the name table and select a name
  def extractName(ttf, data) do
    raw = rawTable(ttf, "name", data)
    if raw do
    <<_fmt::16, nRecords::16, strOffset::16, r::binary>> = raw
    #IO.puts "Name table format #{fmt}"
    recs = readNameRecords([], r, nRecords)
    # pick best supported platform/encoding
    selected = recs
               |> Enum.map(fn r -> {r.platform, r.encoding} end)
               |> findPreferredEncoding
    recs = if selected != nil do
      Enum.filter(recs, fn r -> {r.platform, r.encoding} == selected end)
    else
      recs
    end
    # and just parse that one
    names = Enum.map(recs, fn(r)->recordToName(r, strOffset, raw) end)
    #prefer PS name
    name6 = case Enum.find(names, fn({id, _}) -> id == 6 end) do
      {_, val} -> val
      _ -> nil
    end
    name4 = case Enum.find(names, fn({id, _}) -> id == 4 end) do
      {_, val} -> val
      _ -> nil
    end
    name1 = case Enum.find(names, fn({id, _}) -> id == 1 end) do
      {_, val} -> val
      _ -> nil
    end
    psName = cond do
      name6 -> name6
      name4 -> name4
      name1 -> name1
      true -> "NO-VALID-NAME"
    end
    #replace spaces in psName with dashes
    #self.familyName = names[1] or psName
    #self.styleName = names[2] or 'Regular'
    #self.fullName = names[4] or psName
    #self.uniqueFontID = names[3] or psName
    %{ttf | name: psName}
    else
    %{ttf | name: "NO-VALID-NAME"}
    end
  end

  defmodule FontTable do
    @moduledoc false
    defstruct name: "", checksum: 0, offset: 0, length: 0
  end

  # read in the font tables
  def readTables(data, numTables) do
    # each table definition is 16 bytes
    tableDefs = binary_part(data, 0, numTables * 16)
    for << <<tag::binary-size(4), checksum::32, offset::32, length::32>> <- tableDefs >>, do: %FontTable{name: tag, checksum: checksum, offset: offset, length: length}
  end
 
  defp readOffset(offsets, data, 0), do: {offsets, data}
  defp readOffset(offsets, <<offset::32, rem::binary>>, count) do
    readOffset([offset | offsets], rem, count-1)
  end

  defp readNameRecords(recs, _data, 0), do: recs
  defp readNameRecords(recs, data, nRecs) do
    <<platform::16, encoding::16, language::16, nameID::16, length::16, offset::16, remaining::binary>> = data
    r = %{platform: platform, encoding: encoding, lang: language, nameID: nameID, length: length, offset: offset}
    readNameRecords([r | recs], remaining, nRecs-1)
  end


  # Platform 3 (Windows) -- encoding 1 (UCS-2) and 10 (UCS-4)
  defp recordToName(%{platform: 3} = record, offset, data) do
    readUTF16Name(record, offset, data)
  end
  # Platform 0 (Unicode)
  defp recordToName(%{platform: 0} = record, offset, data) do
    readUTF16Name(record, offset, data)
  end
  # Platform 2 (deprecated; identical to platform 0)
  defp recordToName(%{platform: 2, encoding: 1} = record, offset, data) do
    readUTF16Name(record, offset, data)
  end
  # ASCII(UTF-8) for most platform/encodings
  defp recordToName(record, offset, data) do
    raw = binary_part(data, record.offset + offset, record.length)
    {record.nameID, to_string(raw)}
  end
  # handle the unicode (UTF-16BE) names
  defp readUTF16Name(record, offset, data) do
    raw = binary_part(data, record.offset + offset, record.length)
    chars = :unicode.characters_to_list(raw, {:utf16, :big})
    {record.nameID, to_string(chars)}
  end

  def findPreferredEncoding(candidates) do
    # Select a Unicode CMAP by preference
    preferred = [
      # 32-bit Unicode formats
      {3,10}, {0, 6}, {0, 4},
      # 16-bit Unicode formats
      {3,1}, {0,3}, {0,2}, {0, 1}, {0, 0},
      # Windows symbol font (usually unicode)
      {3, 0}
    ]
      preferred |> Enum.find(fn {plat, enc} -> {plat, enc} in candidates end)
  end

  def extractMetrics(ttf, data) do
    _ = """
    *flags        Font flags
    *ascent       Typographic ascender in 1/1000ths of a point
    *descent      Typographic descender in 1/1000ths of a point
    *capHeight    Cap height in 1/1000ths of a point (0 if not available)
    *bbox         Glyph bounding box [l,t,r,b] in 1/1000ths of a point
    *unitsPerEm   Glyph units per em
    *italicAngle  Italic angle in degrees ccw
    *stemV        stem weight in 1/1000ths of a point (approximate)

    defaultWidth   default glyph width in 1/1000ths of a point
    charWidths     dictionary of character widths for every supported UCS character
    code
    """

    raw_head = rawTable(ttf, "head", data)

    {bbox, unitsPerEm} = if raw_head do
      <<_major::16, _minor::16, _rev::32, _checksumAdj::32,
      0x5F, 0x0F, 0x3C, 0xF5, _flags::16, unitsPerEm::16,
      _created::signed-64, _modified::signed-64,
      minx::signed-16, miny::signed-16, maxx::signed-16, maxy::signed-16,
      _macStyle::16, _lowestPPEM::16, _fontDirectionHint::signed-16,
      _glyphMappingFmt::signed-16, _glyphDataFmt::signed-16>> = raw_head
      {[minx, miny, maxx, maxy], unitsPerEm}
    else
      {[-100, -100, 100, 100], 1000}
    end

    raw_os2 = rawTable(ttf, "OS/2", data)
    measured = if raw_os2 do
      # https://www.microsoft.com/typography/otspec/os2.htm
      # match version 0 struct, extract additional fields as needed
      # usWidthClass = Condensed < Normal < Expanded
      # fsType = flags that control embedding
      # unicode range 1-4 are bitflags that identify charsets
      # selFlags = italic, underscore, bold, strikeout, outlined...
      # TODO: conform to fsType restrictions
      <<os2ver::16, _avgCharWidth::signed-16, usWeightClass::16,
      _usWidthClass::16, _fsType::16,
      _subXSize::signed-16,_subYSize::signed-16,
      _subXOffset::signed-16,_subYOffset::signed-16,
      _superXSize::signed-16,_superYSize::signed-16,
      _superXOffset::signed-16,_superYOffset::signed-16,
      _strikeoutSize::signed-16, _strikeoutPos::signed-16,
      familyClass::signed-16, _panose::80,
      _unicodeRange1::32, _unicodeRange2::32, _unicodeRange3::32, _unicodeRange4::32,
      _vendorID::32, _selFlags::16, _firstChar::16, _lastChar::16,
      typoAscend::signed-16,typoDescend::signed-16,
      _typoLineGap::signed-16, _winAscent::16, _winDescent::16,
      v0rest::binary>> = raw_os2

      Logger.debug "OS/2 ver #{os2ver} found"

      # os2ver 1 or greater has code page range fields
      v1rest = if os2ver > 0 do
        <<_cp1::32, _cp2::32, v1rest::binary>> = v0rest
        v1rest
      else
        nil
      end

      # if we have a v2 or higher struct we can read out
      # the xHeight and capHeight
      capHeight = if os2ver > 1 and v1rest do
        <<_xHeight::signed-16, capHeight::signed-16,
        _defaultChar::16, _breakChar::16, _maxContext::16,
        _v2rest::binary>> = v1rest
        capHeight
      else
        0.7 * unitsPerEm
      end

      # for osver > 4 also fields:
      # lowerOpticalPointSize::16, upperOpticalPointSize::16

      %{ttf | ascent: typoAscend, descent: typoDescend, capHeight: capHeight, usWeightClass: usWeightClass, familyClass: familyClass}
    else
      Logger.debug "No OS/2 info, synthetic data"
      %{ttf | ascent: Enum.at(bbox, 3), descent: Enum.at(bbox, 1), capHeight: Enum.at(bbox, 3), usWeightClass: 500}
    end

    # There's no way to get stemV from a TTF file short of analyzing actual outline data
    # This fuzzy formula is taken from pdflib sources, but we could just use 0 here
    stemV = 50 + trunc((measured.usWeightClass / 65.0) * (measured.usWeightClass / 65.0))

    extractMoreMetrics(%{measured | bbox: bbox, unitsPerEm: unitsPerEm, stemV: stemV}, data)
  end
  defp extractMoreMetrics(ttf, data) do
    #TODO: these should be const enum somewhere
    flagFIXED    = 0b0001
    flagSERIF    = 0b0010
    flagSYMBOLIC = 0b0100
    flagSCRIPT   = 0b1000
    flagITALIC = 0b1000000
    #flagALLCAPS = 1 <<< 16
    #flagSMALLCAPS = 1 <<< 17
    flagFORCEBOLD = 1 <<< 18

    #flags, italic angle, default width
    raw_post = rawTable(ttf, "post", data)
    {itals, fixed, forcebold, italic_angle} = if raw_post do
      <<_verMajor::16, _verMinor::16,
      italicMantissa::signed-16, italicFraction::16,
      _underlinePosition::signed-16, _underlineThickness::signed-16,
      isFixedPitch::32, _rest::binary>> = raw_post
      # this is F2DOT14 format defined in OpenType standard
      italic_angle = italicMantissa + italicFraction / 16384.0


      # if SEMIBOLD or heavier, set forcebold flag
      forcebold = if ttf.usWeightClass >= 600, do: flagFORCEBOLD, else: 0

      # a non-zero angle sets the italic flag
      itals = if italic_angle != 0, do: flagITALIC, else: 0

      # mark it fixed pitch if needed
      fixed = if isFixedPitch > 0, do: flagFIXED, else: 0
      {itals, fixed, forcebold, italic_angle}
    else
      {0, 0, 0, 0}
    end

    # SERIF and SCRIPT can be derived from sFamilyClass in OS/2 table
    class = ttf.familyClass >>> 8
    serif = if Enum.member?(1..7, class), do: flagSERIF, else: 0
    script = if class == 10, do: flagSCRIPT, else: 0
    flags = flagSYMBOLIC ||| itals ||| forcebold ||| fixed ||| serif ||| script

    #hhea
    raw_hhea = rawTable(ttf, "hhea", data)
    if raw_hhea do
      <<_verMajor::16, _verMinor::16,
      _ascender::signed-16, _descender::signed-16,
      _linegap::signed-16, _advanceWidthMax::16,
      _minLeftBearing::signed-16, _minRightBearing::signed-16,
      _xMaxExtent::signed-16, _caretSlopeRise::16, _caretSlopeRun::16,
      _caretOffset::signed-16, _reserved::64, _metricDataFormat::signed-16,
      numMetrics::16>> = raw_hhea
      #maxp
      #number of glyphs -- will need to subset if more than 255
      #hmtx (glyph widths)
      raw_hmtx = rawTable(ttf, "hmtx", data)
      range = 1..numMetrics
      gw = Enum.map(range, fn(x) -> getGlyphWidth(raw_hmtx, x-1) end)
      %{ttf | italicAngle: italic_angle, flags: flags, glyphWidths: gw, defaultWidth: Enum.at(gw, 0)}
    else
      ttf
    end

  end
  defp getGlyphWidth(hmtx, index) do
    <<width::16>> = binary_part(hmtx, index*4, 2)
    width
  end

  # mark what portion of the font is embedded
  # this may get more complex when we do proper subsetting
  def markEmbeddedPart(ttf, data) do
    embedded = if ttf.isCFF do
      #rawTable(ttf, "CFF ", data)
      data
    else
      data
    end
    %{ttf | :embed => embedded}
  end

  #cmap header
  def extractCMap(ttf, data) do
    raw_cmap = rawTable(ttf, "cmap", data)
    if raw_cmap do
    # version, numTables
    <<_version::16, numtables::16, cmaptables::binary>> = raw_cmap
    # read in tableoffsets (plat, enc, offset)
    {cmapoffsets, _cmapdata} = readCMapOffsets([], cmaptables, numtables)

    # find the best available format
    selected = cmapoffsets
               |> Enum.map(fn {plat, enc, _} -> {plat, enc} end)
               |> findPreferredEncoding

    # if we found a preferred format, locate it
    {plat, enc, off} = if selected != nil do
      Enum.find(cmapoffsets, fn {plat, enc, _} -> {plat, enc} == selected end)
    else
      # no preferred format available, just handle the first one
      hd(cmapoffsets)
    end

    #we need the table's offset and length to find subtables
    {raw_off, raw_len} = lookupTable(ttf, "cmap")
    raw_cmap = binary_part(data, raw_off + off, raw_len - off)
    cid2gid = readCMapData(plat, enc, raw_cmap, %{})

    # reverse the lookup as naive ToUnicode map
    gid2cid = Enum.map(cid2gid, fn ({k, v}) -> {v, k} end) |> Map.new
    %{ttf | :cid2gid => cid2gid, :gid2cid => gid2cid}
    else
      ttf
    end
  end

  # read in the platform, encoding, offset triplets
  defp readCMapOffsets(tables, data, 0) do
    {tables, data}
  end
  defp readCMapOffsets(tables, data, nTables) do
    <<platform::16, encoding::16, offset::32, remaining::binary>> = data
    t = {platform, encoding, offset}
    readCMapOffsets([t | tables], remaining, nTables-1)
  end

  # read CMap format 4 (5.2.1.3.3: Segment mapping to delta values)
  # this is the most useful one for the majority of modern fonts
  # used for Windows Unicode mappings (platform 3 encoding 1) for BMP
  defp readCMapData(_platform, _encoding, <<4::16, _length::16, _lang::16, subdata::binary>>, cmap) do
    <<doubleSegments::16,
    _searchRange::16,
    _entrySelector::16,
    _rangeShift::16,
    segments::binary>> = subdata
    #IO.puts "READ UNICODE TABLE #{platform} #{encoding}"
    segmentCount = div doubleSegments, 2
    # segment end values
    {endcodes, ecDone} = readSegmentData([], segments, segmentCount)
    #reserved::16
    <<_reserved::16, skipRes::binary>> = ecDone
    # segment start values
    {startcodes, startDone} = readSegmentData([], skipRes, segmentCount)
    # segment delta values
    {deltas, deltaDone} = readSignedSegmentData([], startDone, segmentCount)
    # segment range offset values
    {offsets, _glyphData} = readSegmentData([], deltaDone, segmentCount)
    # combine the segment data we've read in
    segs = List.zip([startcodes, endcodes, deltas, offsets])
           |> Enum.reverse
    # generate the character-to-glyph map
    # TODO: also generate glyph-to-character map
    segs
    |> Enum.with_index
    |> Enum.reduce(%{}, fn({x, index}, acc) -> mapSegment(x, acc, index, deltaDone) end)
    |> Map.merge(cmap)
  end

  # read CMap format 12 (5.2.1.3.7 Segmented coverage)
  # This is required by Windows fonts (Platform 3 encoding 10) that have UCS-4 characters
  # and is a SUPERSET of the data stored in format 4
  defp readCMapData(_platform, _encoding, <<12::16, _::16, _length::32, _lang::32, groups::32, subdata::binary>>, cmap) do
    readCMap12Entry([], subdata, groups)
    |> Enum.reduce(%{}, fn({s,e,g}, acc) -> mapCMap12Entry(s,e,g,acc) end)
    |> Map.merge(cmap)
  end

  #unknown formats we ignore for now
  defp readCMapData(_platform, _encoding, <<_fmt::16, _subdata::binary>>, cmap) do
    #IO.inspect {"READ", fmt, platform, encoding}
    cmap
  end

  defp mapCMap12Entry(startcode, endcode, glyphindex, charmap) do
    offset = glyphindex-startcode
    startcode..endcode
        |> Map.new(fn(x) -> {x, x + offset} end)
        |> Map.merge(charmap)
  end
  defp readCMap12Entry(entries, _, 0), do: entries
  defp readCMap12Entry(entries, data, count) do
    <<s::32, e::32, g::32, remaining::binary>> = data
    readCMap12Entry([{s,e,g} | entries], remaining, count - 1)
  end

  defp mapSegment({0xFFFF, 0xFFFF, _, _}, charmap, _, _) do
    charmap
  end
  defp mapSegment({first, last, delta, 0}, charmap, _, _) do
    first..last
     |> Map.new(fn(x) -> {x, (x + delta) &&& 0xFFFF} end)
     |> Map.merge(charmap)
  end
  defp mapSegment({first, last, delta, offset}, charmap, segment_index, data) do
    first..last
     |> Map.new(fn(x) ->
       offsetx = (x - first) * 2 + offset + 2 * segment_index
       <<glyph::16>> = binary_part(data, offsetx, 2)
       g = if glyph == 0 do 0 else glyph + delta end
       {x, g &&& 0xFFFF}
     end)
     |> Map.merge(charmap)
  end

  defp readSegmentData(vals, data, 0) do
    {vals, data}
  end
  defp readSegmentData(vals, <<v::16, rest::binary>>, remaining) do
    readSegmentData([v | vals], rest, remaining-1)
  end
  defp readSignedSegmentData(vals, data, 0) do
    {vals, data}
  end
  defp readSignedSegmentData(vals, <<v::signed-16, rest::binary>>, remaining) do
    readSegmentData([v | vals], rest, remaining-1)
  end

  def extractFeatures(ttf, data) do
    {subS, subF, subL} = if hasTable?(ttf, "GSUB"), do: extractOffHeader("GSUB", ttf, data), else: {[], [], []}
    {posS, posF, posL} = if hasTable?(ttf, "GPOS"), do: extractOffHeader("GPOS", ttf, data), else: {[], [], []}
    #read in definitions
    gdef = rawTable(ttf, "GDEF", data)
    definitions = if gdef != nil, do: extractGlyphDefinitionTable(gdef), else: nil

    %{ttf | 
      substitutions: {subS, subF, subL},
      positions: {posS, posF, posL},
      definitions: definitions
    }
  end

  #returns script/language map, feature list, lookup tables
  defp extractOffHeader(table, ttf, data) do
    raw = rawTable(ttf, table, data)
    if raw == nil do
      Logger.debug "No #{table} table"
    end
    <<versionMaj::16, versionMin::16,
    scriptListOff::16, featureListOff::16,
    lookupListOff::16, _::binary>> = raw
    #if 1.1, also featureVariations::u32
    if {versionMaj, versionMin} != {1, 0} do
      Logger.debug "#{table} Header #{versionMaj}.#{versionMin}"
    end

    lookupList = subtable(raw, lookupListOff)
    <<nLookups::16, ll::binary-size(nLookups)-unit(16), _::binary>> = lookupList
    # this actually gives us offsets to lookup tables
    lookups = for << <<x::16>> <- ll >>, do: x
    lookupTables = lookups
         |> Enum.map(fn x -> getLookupTable(x, lookupList) end)

    # get the feature array
    featureList = subtable(raw, featureListOff)
    features = parseFeatures(featureList)

    scriptList = subtable(raw, scriptListOff)
    <<nScripts::16, sl::binary-size(nScripts)-unit(48), _::binary>> = scriptList
    scripts = for << <<tag::binary-size(4), offset::16>> <- sl >>, do: {tag, offset}
    scripts = scripts
              |> Enum.map(fn {tag, off} -> readScriptTable(tag, scriptList, off) end)
              |> Map.new

    {scripts, features, lookupTables}
  end
  defp extractGlyphDefinitionTable(table) do
    <<versionMaj::16, versionMin::16,
    glyphClassDef::16, _attachList::16,
    _ligCaretList::16, markAttachClass::16,
    rest::binary>> = table
    # 1.2 also has 16-bit offset to MarkGlyphSetsDef
    markGlyphSets = if versionMaj >= 1 and versionMin >= 2 do
      <<markGlyphSets::16, _::binary>> = rest
      if markGlyphSets == 0, do: nil, else: markGlyphSets
    else
      nil
    end
    # 1.3 also has 32-bit offset to ItemVarStore
    #Logger.debug "GDEF #{versionMaj}.#{versionMin}"

    # predefined classes for use with GSUB/GPOS flags
    # 1 = Base, 2 = Ligature, 3 = Mark, 4 = Component
    glyphClassDef = if glyphClassDef > 0, do: parseGlyphClass(subtable(table, glyphClassDef)), else: nil
    # mark attachment class (may be NULL; used with flag in GPOS/GSUB lookups)
    markAttachClass = if markAttachClass > 0, do: parseGlyphClass(subtable(table, markAttachClass)), else: nil
    # mark glyph sets (may be NULL)
    glyphSets = if markGlyphSets != nil do
      mgs = subtable(table, markGlyphSets)
      <<_fmt::16, nGlyphSets::16, gsets::binary-size(nGlyphSets)-unit(32), _::binary>> = mgs 
      for << <<off::32>> <- gsets>>, do: parseCoverage(subtable(mgs, off))
    else
      nil
    end

    _mgs = markGlyphSets
    %{attachments: markAttachClass, classes: glyphClassDef, mark_sets: glyphSets}
  end

  # this should probably be an actual map of tag: [indices]
  def parseFeatures(data) do
    <<nFeatures::16, fl::binary-size(nFeatures)-unit(48), _::binary>> = data
    features = for << <<tag::binary-size(4), offset::16>> <- fl >>, do: {tag, offset}
    features
    |> Enum.map(fn {t, o} -> readLookupIndices(t, o, data) end)
  end

  #returns {lookupType, lookupFlags, [subtable offsets], <<raw table bytes>>, mark filtering set}
  defp getLookupTable(offset, data) do
      tbl = subtable(data, offset)
      <<lookupType::16, flags::16, nsubtables::16, st::binary-size(nsubtables)-unit(16), rest::binary>> = tbl
      #if flag bit for markfilteringset, also markFilteringSetIndex::16
      mfs = if flags &&& 0x0010 do
        <<mfs::16, _::binary>> = rest
        mfs
      else
        nil
      end
      subtables = for << <<y::16>> <- st >>, do: y
      {lookupType, flags, subtables, tbl, mfs}
  end
  defp readScriptTable(tag, data, offset) do
    script_table =  subtable(data, offset)
    <<defaultOff::16, nLang::16, langx::binary-size(nLang)-unit(48), _::binary>> = script_table
    langs = for << <<tag::binary-size(4), offset::16>> <- langx >>, do: {tag, offset}
    langs = langs
            |> Enum.map(fn {tag, offset} -> readFeatureIndices(tag, offset, script_table) end)
            |> Map.new
    langs = if defaultOff == 0 do
      langs
    else
      {_, indices} = readFeatureIndices(nil, defaultOff, script_table)
      Map.put(langs, nil, indices)
    end
    {tag, langs}
  end
  defp readFeatureIndices(tag, offset, data) do
    feature_part = subtable(data, offset)
    <<reorderingTable::16, req::16, nFeatures::16, fx::binary-size(nFeatures)-unit(16), _::binary>> = feature_part
    if reorderingTable != 0 do
      Logger.debug "Lang #{tag} has a reordering table"
    end
    indices = for << <<x::16>> <- fx >>, do: x
    indices = if req == 0xFFFF, do: indices, else: [req | indices]
    {tag, indices}
  end
  defp readLookupIndices(tag, offset, data) do
    lookup_part = subtable(data, offset)
    <<featureParamsOffset::16, nLookups::16, fx::binary-size(nLookups)-unit(16), _::binary>> = lookup_part
    if featureParamsOffset != 0 do
      Logger.debug "Feature #{tag} has feature params"
    end
    indices = for << <<x::16>> <- fx >>, do: x
    {tag, indices}
  end

  def parseGlyphClass(<<1::16, start::16, nGlyphs::16, classes::binary-size(nGlyphs)-unit(16), _::binary>>) do
    classes = for << <<class::16>> <- classes >>, do: class
    classes
    |> Enum.with_index(start)
    |> Map.new(fn {class, glyph} -> {glyph, class} end)
  end
  def parseGlyphClass(<<2::16, nRanges::16, ranges::binary-size(nRanges)-unit(48), _::binary>>) do
    ranges = for << <<first::16, last::16, class::16>> <- ranges >>, do: {first, last, class}
    ranges
  end

  # parse coverage tables
  def parseCoverage(<<1::16, nrecs::16, glyphs::binary-size(nrecs)-unit(16), _::binary>>) do
    for << <<x::16>> <- glyphs >>, do: x
  end
  def parseCoverage(<<2::16, nrecs::16, ranges::binary-size(nrecs)-unit(48), _::binary>>) do
    for << <<startg::16, endg::16, covindex::16>> <- ranges >>, do: {startg, endg, covindex}
  end

  def parseAlts(table, altOffset) do
    <<nAlts::16, alts::binary-size(nAlts)-unit(16), _::binary>> = subtable(table, altOffset)
    for << <<x::16>> <- alts >>, do: x
  end

  def parseLigatureSet(table, lsOffset) do
    <<nrecs::16, ligat::binary-size(nrecs)-unit(16), _::binary>> = subtable(table, lsOffset)
    ligaOff = for << <<x::16>> <- ligat >>, do: x
    ligaOff
    |> Enum.map(fn x -> subtable(table, lsOffset + x) end)
    |> Enum.map(fn <<g::16, nComps::16, rest::binary>> ->  {g, nComps-1, rest} end)
    |> Enum.map(fn {g, n, data} ->
      <<recs::binary-size(n)-unit(16), _::binary>> = data
      gg = for << <<x::16>> <- recs >>, do: x
      {g, gg}
    end)
  end
  def parseContextSubRule1(rule) do
    <<nGlyphs::16, substCount::16, rest::binary>> = rule
    # subtract one since initial glyph handled by coverage
    glyphCount = nGlyphs - 1
    <<input::binary-size(glyphCount)-unit(16), 
      substRecs::binary-size(substCount)-unit(32), 
      _::binary>> = rest

    input_glyphs = for << <<g::16>> <- input >>, do: g
    substRecords = for << <<x::16, y::16>> <- substRecs >>, do: {x, y}
    {input_glyphs, substRecords}
  end

  def parseChainedSubRule2(rule) do
    <<btCount::16, bt::binary-size(btCount)-unit(16),
    nGlyphs::16, rest::binary>> = rule
    # subtract one since initial glyph handled by coverage
    glyphCount = nGlyphs - 1
    <<input::binary-size(glyphCount)-unit(16), 
      laCount::16, la::binary-size(laCount)-unit(16),
      substCount::16,
      substRecs::binary-size(substCount)-unit(32), 
      _::binary>> = rest

    backtrack = for << <<g::16>> <- bt >>, do: g
    lookahead = for << <<g::16>> <- la >>, do: g
    input_glyphs = for << <<g::16>> <- input >>, do: g
    substRecords = for << <<x::16, y::16>> <- substRecs >>, do: {x, y}
    {backtrack, input_glyphs, lookahead, substRecords}
  end

  def parseAnchor(<<_fmt::16, xCoord::signed-16, yCoord::signed-16, _rest::binary>>) do
    # anchorTable (common table)
    # coords are signed!
    # fmt = 1, xCoord::16, yCoord::16
    # fmt = 2, xCoord::16, yCoord::16, index to glyph countour point::16
    # fmt = 3, xCoord::16, yCoord::16, device table offset (for x)::16, device table offset (for y)::16
    {xCoord, yCoord}
  end

  def parseMarkArray(table) do
    <<nRecs::16, records::binary-size(nRecs)-unit(32), _::binary>> = table
    markArray = for << <<markClass::16, anchorTableOffset::16>> <- records >>, do: {markClass, anchorTableOffset}
    markArray
    |> Enum.map(fn {c,o} -> {c, parseAnchor(subtable(table, o))} end)
  end


  def parsePairSet(table, offset, fmtA, fmtB) do
    sizeA = valueRecordSize(fmtA)
    sizeB = valueRecordSize(fmtB)
    data = binary_part(table, offset, byte_size(table) - offset)
    # valueRecordSize returns size in bytes
    pairSize = (2 + sizeA + sizeB)
    <<nPairs::16, pairdata::binary>> = data
    pairs = for << <<glyph::16, v1::binary-size(sizeA), v2::binary-size(sizeB)>> <- binary_part(pairdata, 0, pairSize * nPairs) >>, do: {glyph, v1, v2}
    pairs = pairs
      |> Enum.map(fn {g,v1,v2} -> {g, readPositioningValueRecord(fmtA, v1), readPositioningValueRecord(fmtB, v2)} end)
    pairs
  end
  # ValueRecord in spec
  def readPositioningValueRecord(0, _), do: nil
  def readPositioningValueRecord(format, bytes) do
    # format is bitset of fields to read for each records
    {xPlace, xprest} = extractValueRecordVal(format &&& 0x0001, bytes)
    {yPlace, yprest} = extractValueRecordVal(format &&& 0x0002, xprest)
    {xAdv, xarest} = extractValueRecordVal(format &&& 0x0004, yprest)
    {yAdv, _xyrest} = extractValueRecordVal(format &&& 0x0008, xarest)

    #TODO: also offsets to device table
    {xPlace, yPlace, xAdv, yAdv}
  end

  defp extractValueRecordVal(_flag, ""), do: {0, ""}
  defp extractValueRecordVal(flag, data) do
    if flag != 0 do
      <<x::signed-16, r::binary>> = data
      {x, r}
    else
      {0, data}
    end
  end

  def valueRecordSize(format) do
    flags = for << x::1 <- <<format>> >>, do: x
    # record size is 2 bytes per set flag in the format spec
    Enum.count(flags, fn x -> x == 1 end) * 2
  end

end

