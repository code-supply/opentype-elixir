defmodule OpenType do
  @moduledoc """
  Provides parsers and utilities
  """

  alias OpenType.Parser
  alias OpenType.Substitutions
  alias OpenType.Positioning
  alias OpenType.Layout
  alias OpenType.GlyphInfo

  @doc """
  Create an empty structure with sensible defaults.

  This will likely be replaced in future with a proper struct.
  """
  def new do
    %{
      :version => 0,
      :tables => [],
      :name => nil,
      :bbox => [],
      :ascent => 0,
      :descent => 0,
      :capHeight => 0,
      :unitsPerEm => 0,
      :usWeightClass => 500,
      :stemV => 0,
      :italicAngle => 0,
      :flags => 0,
      :glyphWidths => [],
      :defaultWidth => 0,
      "SubType" => {:name, "Type0"},
      :embed => nil,
      :cid2gid => %{},
      :gid2cid => %{},
      # GSUB
      :substitutions => nil,
      # GPOS
      :positions => nil,
      # GDEF
      :definitions => nil,
      :isCFF => false,
      :familyClass => 0
    }
  end

  @doc """
  Open and parse a font file.  Returns the parsed font structure.

  The current version assumes an uncompressed OpenType or TrueType font.
  For a font collection, it returns only the first font in the collection.
  """
  def parse_file(filename) do
    f = File.open!(filename)
    data = IO.binread(f, :eof)
    new() |> parse(data)
  end

  @doc """
  Parse the binary data that makes up a font.
  """
  def parse(ttf, data) do
    ttf
    |> Parser.extractVersion(data)
    |> Parser.readHeader(data)
    |> Parser.extractName(data)
    |> Parser.extractMetrics(data)
    |> Parser.markEmbeddedPart(data)
    |> Parser.extractCMap(data)
    |> Parser.extractFeatures(data)
  end

  @doc """
  Returns the list of OpenType features that are enabled by default.

  This list is determined by the OpenType specification. Note that fonts are not required
  to support these features, nor are they necessarily used by all scripts (for example, the
  features for positional forms are typically only used by cursive scripts such as Arabic).
  """
  def default_features do
    [
      # preprocess (compose/decompose, local forms)
      "ccmp",
      "locl",
      # marks (mark-to-base, mark-to-mark, mark position via substitution)
      "mark",
      "mkmk",
      "mset",
      # ligatures (contextual, standard, required)
      "clig",
      "liga",
      "rlig",
      # contextual alts (standard, required)
      "calt",
      "rclt",
      # when kern enabled, also enable palt
      "kern",
      "palt",
      # "opbd", "lfbd", "rtbd", # optical bounds -- requires app support to identify bounding glyphs?
      # cursive (required; best tested with arabic font)
      "curs",
      # positional forms (required; best tested with arabic font)
      "isol",
      "fina",
      "medi",
      "init"
    ]
  end

  @doc """
  Returns a series of positioned glyphs (a tuple of {glyphs, positions}).

  Once a font has been parsed, this function will apply OpenType features to perform substitution
  and positioning. If no features are specified, `default_features/0` will be enabled.

  This version does not apply width or height constraints, line breaking, or a bidirectional algorithm.
  Such layout logic is assumed to be handled by the caller.

  If the script tag is not specified, it will attempt to autodetect it using `OpenType.Layout.detect_script/1`.
  If undetected or unsupported by the font it will fall back to the "DFLT" (default) script tag.

  If the language tag is not specified, it will follow the spec and fall back to the default language.
  """
  def layout_text(ttf, text, features \\ nil, script \\ nil, lang \\ nil) do
    # use the font CMAP to convert the initial text
    # into a series of glyphs
    glyphs =
      text
      |> String.to_charlist()
      |> Enum.map(fn cid -> %GlyphInfo{glyph: Map.get(ttf.cid2gid, cid, 0), codepoints: [cid]} end)

    # detect script if not passed in
    script =
      if script == nil do
        Layout.detect_script(text)
      else
        script
      end

    # shaper = layout.selectshaper(script)
    # {glyphs, glyph_features} = shaper.markLocalFeatures(glyphs)
    # opentype.substitutions(glyphs, font, script, lang, features, glyph_features)

    # see OpenType feature registry for required, never disabled,
    # and recommended features
    features =
      if features == nil do
        default_features()
      else
        features
      end

    # per OpenType spec, enable "palt" when "kern" is enabled
    features = if "kern" in features, do: ["palt" | features], else: features

    # mark any per-glyph features
    {per_glyph_features, assignments} = Layout.shape_glyphs(script, glyphs)

    glyphs =
      if length(assignments) > 0 do
        glyphs
        |> Enum.with_index()
        |> Enum.map(fn {g, i} -> %{g | tag: Enum.at(assignments, i)} end)
      else
        glyphs
      end

    # do the subs
    output =
      glyphs
      |> handle_substitutions(ttf, script, lang, features, per_glyph_features)

    {output, pos} =
      output
      |> position_glyphs(ttf, script, lang, features)

    {output, pos}
  end

  @doc """
  Discover the OpenType features supported by the font.

  This can be used to present optional features to a layout engine or end user.
  """
  def discover_features(ttf) do
    # TODO: add kern if there is a 'kern' table but no GPOS
    {_, gsub_features, _} = ttf.substitutions
    {_, gpos_features, _} = ttf.positions

    (gsub_features ++ gpos_features)
    |> Enum.map(fn {tag, _} -> tag end)
    |> Enum.uniq()
  end

  # is there a particular font table?
  def hasTable?(ttf, name) do
    Enum.any?(ttf.tables, fn x -> x.name == name end)
  end

  # subtitute ligatures, positional forms, stylistic alternates, etc
  # based upon the script, language, and active OpenType features
  defp handle_substitutions(glyphs, ttf, script, lang, active_features, per_glyph_features) do
    # use data in GSUB to do any substitutions
    {scripts, subF, subL} = ttf.substitutions

    # features actually provided by the font
    availableFeatures = getFeatures(scripts, script, lang)

    # combine indices, apply in order given in LookupList table
    lookups =
      availableFeatures
      |> Enum.map(fn x -> Enum.at(subF, x) end)
      |> Enum.filter(fn {tag, _} -> tag in active_features end)
      |> Enum.map(fn {_, l} -> l end)
      |> List.flatten()
      |> Enum.sort()
      |> Enum.uniq()

    # we know which lookups are going to be used
    # we can parse now, update subL, apply below!
    lookup_cache =
      Enum.reduce(lookups, subL, fn x, cache -> Substitutions.parse_lookup_table(x, cache) end)

    # per-glyph lookups
    pgl =
      availableFeatures
      |> Enum.map(fn x -> Enum.at(subF, x) end)
      |> Enum.filter(fn {tag, _} -> tag in per_glyph_features end)
      |> Enum.map(fn {tag, l} -> for i <- l, do: {i, tag} end)
      |> List.flatten()
      |> Map.new()

    # apply the lookups and return the resulting glyphs
    g =
      Enum.reduce(lookups, glyphs, fn x, acc ->
        if pgl != nil and Map.has_key?(pgl, x) do
          Substitutions.apply_substitution(
            Enum.at(lookup_cache, x),
            ttf.definitions,
            lookup_cache,
            Map.get(pgl, x),
            acc
          )
        else
          Substitutions.apply_substitution(
            Enum.at(lookup_cache, x),
            ttf.definitions,
            lookup_cache,
            nil,
            acc
          )
        end
      end)

    g
  end

  # adjusts positions of glyphs based on script, language, and OpenType features
  # Used for kerning, optical alignment, diacratics, etc
  defp position_glyphs(glyphs, ttf, script, lang, active_features) do
    # initially just use glyph width as xadvance
    # this is sufficient if kerning information is missing
    # TODO: handle vertical writing
    positions =
      glyphs
      |> Stream.map(fn g -> Enum.at(ttf.glyphWidths, g.glyph, ttf.defaultWidth) end)
      |> Stream.map(fn advance -> {:std_width, 0, 0, advance, 0} end)
      |> Enum.to_list()

    # TODO: if no GPOS, fallback to kern table
    #
    # use data in the GPOS and BASE table
    # to kern, position, and join
    {scripts, features, lookups} = ttf.positions

    availableFeatures = getFeatures(scripts, script, lang)

    # each feature provides lookup indices
    # combine indices, apply in order given in LookupList table
    indices =
      availableFeatures
      |> Stream.map(fn x -> Enum.at(features, x) end)
      |> Stream.filter(fn {tag, _} -> tag in active_features end)
      |> Enum.map(fn {_, l} -> l end)
      |> List.flatten()
      |> Enum.sort()
      |> Enum.uniq()

    # we can parse now, update subL, apply below!
    lookup_cache =
      Enum.reduce(indices, lookups, fn x, cache -> Positioning.parse_lookup_table(x, cache) end)

    isRTL = UnicodeData.right_to_left?(script)
    # apply the lookups
    # returns glyphs, positioning, cursive attachments
    {g, p} =
      Enum.reduce(indices, {glyphs, positions}, fn x, acc ->
        Positioning.apply_lookup(
          Enum.at(lookup_cache, x),
          ttf.definitions,
          lookup_cache,
          isRTL,
          acc
        )
      end)

    # make cursive and mark positioning adjustments
    # first apply any cursive adjustments
    cDeltas = g |> Enum.map(& &1.cursiveDelta)
    {p, _deltas} = Positioning.adjustCursiveOffset(p, cDeltas)
    # then apply any mark adjustments
    mDeltas = g |> Enum.map(& &1.markDelta)
    {p, _deltas} = Positioning.adjustMarkOffsets(p, mDeltas, isRTL)

    g = g |> Enum.map(& &1.glyph)

    # if script is RTL, reverse
    if isRTL do
      {Enum.reverse(g), Enum.reverse(p)}
    else
      {g, p}
    end
  end

  # given a script and language, get the appropriate features
  # (falling back as appropriate)
  defp getFeatures([], _script, _lang) do
    []
  end

  defp getFeatures(scripts, script, lang) do
    # Fallback to "DFLT", "dflt", or "latn" script; else ignore all
    selected_script =
      scripts[script] || scripts["DFLT"] || scripts["dflt"] || scripts["latn"] || %{}

    # Fallback to nil (default) language for script
    selected_script[lang] || selected_script[nil] || []
  end
end
