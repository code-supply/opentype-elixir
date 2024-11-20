defmodule OpenType.Substitutions do
  alias OpenType.Parser
  alias OpenType.GlyphInfo
  require Logger

  # ==============================================
  # GSUB glyph substitutions
  # Used for ligatures, swashes, alternate forms
  # if a lookup type is as-yet unsupported
  # simply passes through the input
  # ==============================================

  # parse a lookup table
  def parse_lookup_table(index, lookups) do
    lookup = lookups |> Enum.at(index)

    parsed =
      case lookup do
        # extended lookup table, need to return actual lookup type
        {7, flag, offsets, table, mfs} ->
          {actual_type, output} = parse_lookup(7, offsets, table)
          {:parsed, actual_type, flag, mfs, output}

        # standard lookup table
        {n, flag, offsets, table, mfs} ->
          {:parsed, n, flag, mfs, parse_lookup(n, offsets, table)}

        # already parsed (or unparsable), ignore
        _ ->
          lookup
      end

    # replace with parsed content and return
    if parsed != lookup do
      lookups |> List.replace_at(index, parsed)
    else
      lookups
    end
  end

  defp parse_and_apply({:parsed, type, flag, mfs, data}, gdef, lookups, tag, glyphs) do
    apply_substitution({:parsed, type, flag, mfs, data}, gdef, lookups, tag, glyphs)
  end

  defp parse_and_apply({7, flag, offsets, data, mfs}, gdef, lookups, tag, glyphs) do
    {actual_type, output} = parse_lookup(7, offsets, data)
    val = {:parsed, actual_type, flag, mfs, output}
    apply_substitution(val, gdef, lookups, tag, glyphs)
  end

  defp parse_and_apply({type, flag, offsets, data, mfs}, gdef, lookups, tag, glyphs) do
    val = {:parsed, type, flag, mfs, parse_lookup(type, offsets, data)}
    apply_substitution(val, gdef, lookups, tag, glyphs)
  end

  @doc """
  Apply the substitution to the input list of glyphs.
  """
  def apply_substitution({:parsed, type, flag, mfs, data}, gdef, lookups, tag, glyphs)
      when is_list(data) do
    Enum.reduce(data, glyphs, fn subdata, input ->
      apply_substitution({:parsed, type, flag, mfs, subdata}, gdef, lookups, tag, input)
    end)
  end

  # GSUB 1 -- single substitution (one-for-one)
  def apply_substitution({:parsed, 1, _flag, _mfs, sub}, _gdef, _lookups, tag, glyphs) do
    {coverage, replacements} = sub
    replace = fn g -> applySingleSub(g, coverage, replacements) end

    output =
      if tag != nil do
        glyphs
        |> Enum.map(fn g -> if g.tag == tag, do: replace.(g), else: g end)
      else
        Enum.map(glyphs, replace)
      end

    output
  end

  # GSUB 2 - multiple substitution (expand one glyph into several)
  def apply_substitution({:parsed, 2, _flag, _mfs, sub}, _gdef, _, tag, glyphs) do
    {coverage, sequences} = sub

    output =
      if tag != nil do
        glyphs
        |> Enum.map(fn g ->
          if g.tag == tag, do: applyMultiSub(g, coverage, sequences), else: g
        end)
      else
        glyphs
        |> Enum.map(fn g -> applyMultiSub(g, coverage, sequences) end)
      end

    List.flatten(output)
  end

  # GSUB type 3 -- alternate substitution (one-for-one)
  def apply_substitution({:parsed, 3, _flag, _mfs, sub}, _gdef, _, tag, glyphs) do
    {coverage, alts} = sub
    # TODO: seems like there's a way in unicode to specify alt??
    # More research required, for now substitute a random alt
    if tag != nil do
      glyphs
      |> Enum.map(fn g -> if g.tag == tag, do: applyRandomAlt(g, coverage, alts), else: g end)
    end

    Enum.map(glyphs, fn g -> applyRandomAlt(g, coverage, alts) end)
  end

  # GSUB type 4 -- ligature substition (single glyph replaces multiple glyphs)
  def apply_substitution({:parsed, 4, flag, mfs, sub}, gdef, _, tag, glyphs) do
    {coverage, ligaOff} = sub

    if tag != nil do
      IO.puts("GSUB 4 per-glyph #{tag} lookup")
    end

    # TODO: figure out per-glyph-annotation for ligature!
    # TODO: also need to track components through to positioning for GPOS5
    applyLigature(coverage, ligaOff, flag, gdef, mfs, glyphs, [])
  end

  # GSUB type 5 -- contextual substitution
  def apply_substitution({:parsed, 5, _flag, _mfs, sub}, _gdef, lookups, tag, glyphs) do
    if tag != nil do
      IO.puts("GSUB 5 per-glyph #{tag} lookup")
    end

    {format, rules} = sub

    output =
      case format do
        1 ->
          {coverage, rulesets} = rules
          applyContextSub1(coverage, rulesets, lookups, glyphs, [])

        2 ->
          {coverage, rulesets, classes} = rules
          applyContextSub2(coverage, rulesets, classes, lookups, glyphs, [])

        3 ->
          Logger.debug("GSUB 5.3 - contextual substitution")
          glyphs

        _ ->
          Logger.debug("GSUB 5 - contextual substitution format #{format}")
          glyphs
      end

    output
  end

  # GSUB type 6 -- chained contextual substitution
  def apply_substitution({:parsed, 6, flag, mfs, sub}, gdef, lookups, tag, glyphs) do
    {format, rules} = sub

    output =
      case format do
        1 ->
          Logger.debug("GSUB 6.1 - chained substitution")
          glyphs

        2 ->
          if tag != nil do
            IO.puts("GSUB 6 per-glyph #{tag} lookup; type #{format}")
          end

          {coverage, rulesets, btClasses, inputClasses, laClasses} = rules
          # {f, skipped} = filter_glyphs(glyphs, flag, gdef, mfs)
          applyChainingContextSub2(
            coverage,
            rulesets,
            {btClasses, inputClasses, laClasses},
            lookups,
            glyphs,
            []
          )

        # unfilter_glyphs(replaced, skipped)
        3 ->
          {btCoverage, coverage, laCoverage, substRecords} = rules
          {f, skipped} = filter_glyphs(glyphs, flag, gdef, mfs)

          replaced =
            applyChainingContextSub3(
              btCoverage,
              coverage,
              laCoverage,
              substRecords,
              lookups,
              f,
              tag,
              []
            )

          unfilter_glyphs(replaced, skipped)

        _ ->
          Logger.debug("GSUB 6 - chaining substitution format #{format}")
          glyphs
      end

    output
  end

  # GSUB type 7 is only parsed, never applied!!
  def apply_substitution({:parsed, 7, _flag, _mfs, _sub}, _gdef, _lookups, _tag, glyphs) do
    Logger.error("GSUB 7 is for parsing extended tables, not applying!")
    glyphs
  end

  # GSUB type 8 -- reverse chained contextual substitution
  def apply_substitution({:parsed, 8, flag, mfs, sub}, gdef, lookups, tag, glyphs) do
    if tag != nil do
      IO.puts("GSUB 8 per-glyph #{tag} lookup")
    end

    # Logger.debug "GSUB 8 - reverse chaining substitution"
    Logger.debug("GSUB 8 - reverse chaining substitution")
    {btCoverage, coverage, laCoverage, substRecords} = sub
    {f, skipped} = filter_glyphs(glyphs, flag, gdef, mfs)

    replaced =
      applyReverseChainingContext(btCoverage, coverage, laCoverage, substRecords, lookups, f, [])

    output = unfilter_glyphs(replaced, skipped)
    output
  end

  @doc """
  Parse a lookup table into the information needed to resolve it
  """
  def parse_lookup(7, offsets, data) do
    # GSUB type 7 -- extended table
    subtables =
      offsets
      |> Enum.map(fn x ->
        <<1::16, lt::16, off::32>> = binary_part(data, x, 8)
        {lt, Parser.subtable(data, x + off)}
      end)

    # spec says extended type is identical for all subtables
    {actual_type, _} = hd(subtables)

    output =
      subtables
      |> Enum.map(fn {type, table} -> parse_lookup(type, table) end)

    {actual_type, output}
  end

  # parse a lookup (which is expected to have multiple subtables)
  def parse_lookup(type, offsets, data) do
    offsets
    |> Enum.map(fn o -> parse_lookup(type, Parser.subtable(data, o)) end)
  end

  # GSUB 1 - return {coverage, delta | [replacements]}
  def parse_lookup(1, data) do
    <<format::16, covOff::16, rest::binary>> = data
    coverage = Parser.parseCoverage(Parser.subtable(data, covOff))

    replacements =
      case format do
        1 ->
          <<delta::16, _::binary>> = rest
          delta

        2 ->
          <<nGlyphs::16, ga::binary-size(nGlyphs)-unit(16), _::binary>> = rest
          for <<(<<x::16>> <- ga)>>, do: x

        _ ->
          nil
      end

    {coverage, replacements}
  end

  # GSUB 2 - return {coverage, sequences}
  def parse_lookup(2, data) do
    <<_format::16, covOff::16, nSeq::16, subOff::binary-size(nSeq)-unit(16), _::binary>> = data
    coverage = Parser.parseCoverage(Parser.subtable(data, covOff))
    # sequence tables
    seqOffsets = for <<(<<x::16>> <- subOff)>>, do: x

    # sequence table structure identical to alt table
    sequences = Enum.map(seqOffsets, fn seqOffset -> Parser.parseAlts(data, seqOffset) end)
    {coverage, sequences}
  end

  # GSUB 3 - return {coverage, alts}
  def parse_lookup(3, data) do
    <<1::16, covOff::16, nAltSets::16, aoff::binary-size(nAltSets)-unit(16), _::binary>> = data
    coverage = Parser.parseCoverage(Parser.subtable(data, covOff))
    # alternate set tables
    altOffsets = for <<(<<x::16>> <- aoff)>>, do: x
    alts = Enum.map(altOffsets, fn altOffset -> Parser.parseAlts(data, altOffset) end)
    {coverage, alts}
  end

  # GSUB type 4 -- ligature substition (single glyph replaces multiple glyphs)
  def parse_lookup(4, data) do
    # parse ligature table
    <<1::16, covOff::16, nLigSets::16, lsl::binary-size(nLigSets)-unit(16), _::binary>> = data
    # ligature set tables
    ls = for <<(<<x::16>> <- lsl)>>, do: x
    # coverage table
    coverage = Parser.parseCoverage(Parser.subtable(data, covOff))
    # ligatures
    ligaOff = Enum.map(ls, fn lsOffset -> Parser.parseLigatureSet(data, lsOffset) end)
    {coverage, ligaOff}
  end

  #
  # GSUB type 5 -- contextual substitution
  def parse_lookup(5, table) do
    <<format::16, details::binary>> = table

    output =
      case format do
        1 ->
          <<covOff::16, nRulesets::16, srsOff::binary-size(nRulesets)-unit(16), _::binary>> =
            details

          coverage = Parser.parseCoverage(Parser.subtable(table, covOff))
          srs = for <<(<<offset::16>> <- srsOff)>>, do: Parser.subtable(table, offset)

          rulesets =
            srs
            |> Enum.map(fn ruleset ->
              <<nRules::16, srOff::binary-size(nRules)-unit(16), _::binary>> = ruleset
              rules = for <<(<<offset::16>> <- srOff)>>, do: Parser.subtable(ruleset, offset)
              rules |> Enum.map(&Parser.parseContextSubRule1(&1))
            end)

          {coverage, rulesets}

        2 ->
          <<covOff::16, classDefOff::16, nRulesets::16, srsOff::binary-size(nRulesets)-unit(16),
            _::binary>> = details

          coverage = Parser.parseCoverage(Parser.subtable(table, covOff))
          classes = Parser.parseGlyphClass(Parser.subtable(table, classDefOff))

          srs =
            for <<(<<offset::16>> <- srsOff)>>,
              do: if(offset != 0, do: Parser.subtable(table, offset), else: nil)

          rulesets =
            srs
            |> Enum.map(fn ruleset ->
              if ruleset != nil do
                <<nRules::16, srOff::binary-size(nRules)-unit(16), _::binary>> = ruleset
                rules = for <<(<<offset::16>> <- srOff)>>, do: Parser.subtable(ruleset, offset)
                rules |> Enum.map(&Parser.parseContextSubRule1(&1))
              else
                nil
              end
            end)

          {coverage, rulesets, classes}

        3 ->
          nil

        _ ->
          Logger.debug("GSUB 5 - contextual substitution format #{format}")
          nil
      end

    {format, output}
  end

  # GSUB type 6 -- chained contextual substitution
  def parse_lookup(6, table) do
    <<format::16, details::binary>> = table

    output =
      case format do
        1 ->
          Logger.debug("GSUB 6.1 - chained substitution")
          nil

        2 ->
          <<covOff::16, btClassOff::16, inputClassOff::16, laClassOff::16, nClassSets::16,
            classSetOff::binary-size(nClassSets)-unit(16), _::binary>> = details

          coverage = Parser.parseCoverage(Parser.subtable(table, covOff))
          btClasses = Parser.parseGlyphClass(Parser.subtable(table, btClassOff))
          inputClasses = Parser.parseGlyphClass(Parser.subtable(table, inputClassOff))
          laClasses = Parser.parseGlyphClass(Parser.subtable(table, laClassOff))

          srs =
            for <<(<<offset::16>> <- classSetOff)>>,
              do: if(offset != 0, do: Parser.subtable(table, offset), else: nil)

          rulesets =
            srs
            |> Enum.map(fn ruleset ->
              if ruleset != nil do
                <<nRules::16, srOff::binary-size(nRules)-unit(16), _::binary>> = ruleset
                rules = for <<(<<offset::16>> <- srOff)>>, do: Parser.subtable(ruleset, offset)
                rules |> Enum.map(&Parser.parseChainedSubRule2(&1))
              else
                nil
              end
            end)

          {coverage, rulesets, btClasses, inputClasses, laClasses}

        3 ->
          <<backtrackCount::16, backoff::binary-size(backtrackCount)-unit(16), inputCount::16,
            inputOff::binary-size(inputCount)-unit(16), lookaheadCount::16,
            lookaheadOff::binary-size(lookaheadCount)-unit(16), substCount::16,
            substRecs::binary-size(substCount)-unit(32), _::binary>> = details

          backOffsets = for <<(<<x::16>> <- backoff)>>, do: x

          btCoverage =
            Enum.map(backOffsets, fn covOff ->
              Parser.parseCoverage(Parser.subtable(table, covOff))
            end)

          inputOffsets = for <<(<<x::16>> <- inputOff)>>, do: x

          coverage =
            Enum.map(inputOffsets, fn covOff ->
              Parser.parseCoverage(Parser.subtable(table, covOff))
            end)

          lookaheadOffsets = for <<(<<x::16>> <- lookaheadOff)>>, do: x

          laCoverage =
            Enum.map(lookaheadOffsets, fn covOff ->
              Parser.parseCoverage(Parser.subtable(table, covOff))
            end)

          substRecords = for <<(<<x::16, y::16>> <- substRecs)>>, do: {x, y}
          {btCoverage, coverage, laCoverage, substRecords}

        _ ->
          Logger.debug("GSUB 6 - chaining substitution format #{format}")
          nil
      end

    {format, output}
  end

  # GSUB type 8 -- reverse chained contextual substitution (one-for-one)
  def parse_lookup(8, table) do
    # Logger.debug "GSUB 8 - reverse chaining substitution"
    <<1::16, covOff::16, details::binary>> = table

    <<backtrackCount::16, backoff::binary-size(backtrackCount)-unit(16), lookaheadCount::16,
      lookaheadOff::binary-size(lookaheadCount)-unit(16), substCount::16,
      substRecs::binary-size(substCount)-unit(16), _::binary>> = details

    coverage = Parser.parseCoverage(Parser.subtable(table, covOff))
    backOffsets = for <<(<<x::16>> <- backoff)>>, do: x

    btCoverage =
      Enum.map(backOffsets, fn covOff -> Parser.parseCoverage(Parser.subtable(table, covOff)) end)

    lookaheadOffsets = for <<(<<x::16>> <- lookaheadOff)>>, do: x

    laCoverage =
      Enum.map(lookaheadOffsets, fn covOff ->
        Parser.parseCoverage(Parser.subtable(table, covOff))
      end)

    substRecords = for <<(<<x::16>> <- substRecs)>>, do: x
    {btCoverage, coverage, laCoverage, substRecords}
  end

  defp applySingleSub(g, _coverage, nil), do: g

  defp applySingleSub(g, coverage, delta) when is_integer(delta) do
    coverloc = findCoverageIndex(coverage, g.glyph)
    if coverloc != nil, do: %{g | glyph: g.glyph + delta}, else: g
  end

  defp applySingleSub(g, coverage, replacements) do
    coverloc = findCoverageIndex(coverage, g.glyph)
    if coverloc != nil, do: %{g | glyph: Enum.at(replacements, coverloc)}, else: g
  end

  defp applyMultiSub(g, coverage, seq) do
    coverloc = findCoverageIndex(coverage, g.glyph)

    if coverloc != nil do
      replacements = Enum.at(seq, coverloc)
      newG = %{g | glyph: hd(replacements)}

      e =
        tl(replacements)
        |> Enum.map(fn x -> %GlyphInfo{glyph: x, tag: g.tag} end)

      [newG | e]
    else
      g
    end
  end

  defp applyRandomAlt(g, coverage, alts) do
    coverloc = findCoverageIndex(coverage, g.glyph)

    if coverloc != nil do
      candidates = Enum.at(alts, coverloc)
      %{g | glyph: Enum.random(candidates)}
    else
      g
    end
  end

  defp matchLigatureRule?(glyphs, match, flag, gdef, mfs) do
    candidate =
      glyphs
      |> lig_components(length(match), flag, gdef, mfs)
      |> Enum.map(fn {g, _} -> g.glyph end)

    candidate == match
  end

  defp lig_components(glyphs, n, flag, gdef, mfs) do
    glyphs
    |> Stream.with_index(1)
    |> Stream.reject(fn {g, _} -> should_skip_glyph?(g.glyph, flag, gdef, mfs) end)
    |> Stream.take(n)
  end

  defp applyLigature(_coverage, _ligatures, _flag, _gdef, _mfs, [], output),
    do: Enum.reverse(output)

  defp applyLigature(coverage, ligatures, flag, gdef, mfs, [g | glyphs], output) do
    # get the index of a ligature set that might apply
    coverloc = findCoverageIndex(coverage, g.glyph)

    {output, glyphs} =
      if coverloc != nil do
        # find first match in this ligature set (if any)
        lig =
          Enum.find(Enum.at(ligatures, coverloc), fn {_replacement, match} ->
            matchLigatureRule?(glyphs, match, flag, gdef, mfs)
          end)

        if lig != nil do
          # IO.puts "LIG: Match #{inspect lig} for #{inspect g}"
          # replace the current glyph
          {rep, m} = lig
          # some kind of acc for skipped glyphs so they can be placed after ligature 
          # with appropriate componentIDs and mark deltas
          # ie; skip marks
          matched =
            [g | glyphs]
            |> lig_components(length(m) + 1, flag, gdef, mfs)
            |> Stream.map(fn {x, _} -> x.codepoints end)
            |> Enum.concat()

          {_, n_total} =
            glyphs
            |> lig_components(length(m), flag, gdef, mfs)
            |> Enum.to_list()
            |> List.last()

          replacement = %{g | glyph: rep, codepoints: matched, isLigature: true}
          # skip over any matched glyphs
          {skipped, last_component} =
            if n_total != length(m) do
              IO.puts("LIG: Match #{length(m)} glyphs out of #{n_total}")
              # take n_total; if skipped set mComponent else increment compID
              # TODO: we should only set mLigComponent when is mark; need to review
              {markss, lastcompID} =
                glyphs
                |> Stream.take(n_total)
                |> Enum.map_reduce(1, fn g, compID ->
                  if should_skip_glyph?(g.glyph, flag, gdef, mfs),
                    do: {%{g | mLigComponent: compID}, compID},
                    else: {g, compID + 1}
                end)

              {markss |> Enum.filter(&should_skip_glyph?(&1.glyph, flag, gdef, mfs)), lastcompID}
            else
              {[], length(m) + 1}
            end

          # probably want to prepend earlier ignored glyphs to remaining
          {rmarks, remaining} =
            Enum.slice(glyphs, n_total, length(glyphs))
            |> Enum.split_while(&should_skip_glyph?(&1.glyph, flag, gdef, mfs))

          rmarks = rmarks |> Enum.map(fn m -> %{m | mLigComponent: last_component} end)
          # for remaining while mark set compID
          {[replacement | output], skipped ++ rmarks ++ remaining}
        else
          {[g | output], glyphs}
        end
      else
        {[g | output], glyphs}
      end

    applyLigature(coverage, ligatures, flag, gdef, mfs, glyphs, output)
  end

  defp applyContextSub1(_coverage, _rulesets, _lookups, [], output), do: output

  defp applyContextSub1(coverage, rulesets, lookups, [g | glyphs], output) do
    coverloc = findCoverageIndex(coverage, g.glyph)

    {o, glyphs} =
      if coverloc != nil do
        ruleset = Enum.at(rulesets, coverloc)
        # find first match in this ruleset
        # TODO: flag might mean we need to filter ignored categories
        # ie; skip marks
        rule =
          Enum.find(ruleset, fn {input, _} ->
            Enum.take(glyphs, length(input)) |> Enum.map(& &1.glyph) == input
          end)

        if rule != nil do
          {matched, substRecords} = rule
          input = [g | Enum.take(glyphs, length(matched))]
          # IO.puts "GSUB5.1 rule = #{inspect input}"
          replaced =
            substRecords
            |> Enum.reduce(input, fn {inputLoc, lookupIndex}, acc ->
              candidate = Enum.at(acc, inputLoc)
              lookup = Enum.at(lookups, lookupIndex)
              [replacement | _] = parse_and_apply(lookup, nil, lookups, nil, [candidate])
              # IO.puts "GSUB5.1 replace = #{inspect candidate} -> #{inspect replacement}"
              List.replace_at(acc, inputLoc, replacement)
            end)

          # skip over any matched glyphs
          # TODO: handle flags correctly
          # probably want to prepend earlier ignored glyphs to remaining
          # IO.puts "GSUB5.1 replaced = #{inspect replaced}"
          remaining = Enum.slice(glyphs, length(matched), length(glyphs))
          {replaced, remaining}
        else
          {[g], glyphs}
        end
      else
        {[g], glyphs}
      end

    output = output ++ o
    applyContextSub1(coverage, rulesets, lookups, glyphs, output)
  end

  # class-based context
  defp applyContextSub2(_coverage, _rulesets, _classes, _lookups, [], output), do: output

  defp applyContextSub2(coverage, rulesets, classes, lookups, [g | glyphs], output) do
    coverloc = findCoverageIndex(coverage, g.glyph)
    ruleset = Enum.at(rulesets, classifyGlyph(g.glyph, classes))

    {o, glyphs} =
      if coverloc != nil and ruleset != nil do
        # Logger.debug "GSUB5.2 rule = #{inspect ruleset}"
        # find first match in this ruleset
        # TODO: flag might mean we need to filter ignored categories
        # ie; skip marks
        rule =
          Enum.find(ruleset, fn {input, _} ->
            candidates =
              glyphs
              |> Enum.take(length(input))
              |> Enum.map(fn g -> classifyGlyph(g.glyph, classes) end)

            candidates == input
          end)

        if rule != nil do
          {matched, substRecords} = rule
          input = [g | Enum.take(glyphs, length(matched))]

          replaced =
            substRecords
            |> Enum.reduce(input, fn {inputLoc, lookupIndex}, acc ->
              candidate = Enum.at(acc, inputLoc)
              lookup = Enum.at(lookups, lookupIndex)
              [replacement | _] = parse_and_apply(lookup, nil, lookups, nil, [candidate])
              List.replace_at(acc, inputLoc, replacement)
            end)

          # skip over any matched glyphs
          # TODO: handle flags correctly
          # probably want to prepend earlier ignored glyphs to remaining
          remaining = Enum.slice(glyphs, length(matched), length(glyphs))
          {replaced, remaining}
        else
          {[g], glyphs}
        end
      else
        {[g], glyphs}
      end

    output = output ++ o
    applyContextSub2(coverage, rulesets, classes, lookups, glyphs, output)
  end

  # handle class-based format for context chaining
  defp applyChainingContextSub2(_coverage, _rulesets, _classes, _lookups, [], output), do: output

  defp applyChainingContextSub2(
         coverage,
         rulesets,
         {btClasses, inputClasses, laClasses},
         lookups,
         [g | glyphs],
         output
       ) do
    coverloc = findCoverageIndex(coverage, g.glyph)
    ruleset = Enum.at(rulesets, classifyGlyph(g.glyph, inputClasses))

    {o, glyphs} =
      if coverloc != nil and ruleset != nil do
        # find first match
        rule =
          Enum.find(ruleset, fn rule ->
            doesCCS2match(rule, {btClasses, inputClasses, laClasses}, output, g, glyphs)
          end)

        # apply substitutions to input
        if rule != nil do
          {_, im, _, substRecords} = rule
          inputExtra = length(im) - 1
          input = [g | Enum.take(glyphs, inputExtra)]

          replaced =
            substRecords
            |> Enum.reduce(input, fn {inputLoc, lookupIndex}, acc ->
              candidate = Enum.at(acc, inputLoc)
              lookup = Enum.at(lookups, lookupIndex)
              [replacement | _] = parse_and_apply(lookup, nil, lookups, nil, [candidate])
              List.replace_at(acc, inputLoc, replacement)
            end)

          # Logger.debug "GSUB6.2 rule = #{inspect input} =>  #{inspect replaced}"
          {replaced, Enum.drop(glyphs, inputExtra)}
        else
          {[g], glyphs}
        end
      else
        {[g], glyphs}
      end

    output = output ++ o

    applyChainingContextSub2(
      coverage,
      rulesets,
      {btClasses, inputClasses, laClasses},
      lookups,
      glyphs,
      output
    )
  end

  defp doesCCS2match(rule, {btClasses, inputClasses, laClasses}, output, g, glyphs) do
    {btMatch, inputMatch, laMatch, _} = rule
    backtrack = length(btMatch)
    inputExtra = length(inputMatch) - 1
    lookahead = length(laMatch)

    # not enough backtracking or lookahead to even attempt match
    if length(output) < backtrack or length(glyphs) < lookahead + inputExtra do
      false
    else
      # do we match the input
      input = [g] ++ Enum.take(glyphs, inputExtra)

      inputMatches =
        input
        |> Enum.zip(inputMatch)
        |> Enum.all?(fn {g, class} -> classifyGlyph(g.glyph, inputClasses) == class end)

      # do we match backtracking?
      backMatches =
        if backtrack > 0 do
          output
          |> Enum.reverse()
          |> Enum.take(backtrack)
          |> Enum.zip(btMatch)
          |> Enum.all?(fn {g, class} -> classifyGlyph(g.glyph, btClasses) == class end)
        else
          true
        end

      # do we match lookahead
      laMatches =
        if lookahead > 0 do
          glyphs
          |> Enum.drop(inputExtra)
          |> Enum.take(lookahead)
          |> Enum.zip(laMatch)
          |> Enum.all?(fn {g, class} -> classifyGlyph(g.glyph, laClasses) == class end)
        else
          true
        end

      inputMatches and backMatches and laMatches
    end
  end

  # handle reverse context chaining (add to output head instead of tail)
  defp applyReverseChainingContext(_btCoverage, _coverage, _laCoverage, _subst, _, [], output),
    do: output

  defp applyReverseChainingContext(
         btCoverage,
         coverage,
         laCoverage,
         subst,
         lookups,
         glyphs,
         output
       ) do
    backtrack = length(btCoverage)
    lookahead = length(laCoverage)
    # we iterate through glyphs backwards
    # grow output at head while shrinking preceding glyphs
    # current is last glyph in list
    g = List.last(glyphs)

    # backtracking is preceding glyphs
    preceding = Enum.slice(glyphs, 0..-2//1)
    # lookahead is following glyphs (output)

    # enough backtracking or lookahead to even attempt match?
    replacement =
      if length(preceding) < backtrack or length(output) < lookahead do
        g
      else
        # do we match input gylph?
        coverloc = findCoverageIndex(coverage, g.glyph)
        inputMatches = coverloc != nil

        # do we match backtracking?
        backMatches =
          if backtrack > 0 do
            preceding
            |> Enum.reverse()
            |> Enum.take(backtrack)
            |> Enum.zip(btCoverage)
            |> Enum.all?(fn {g, cov} -> findCoverageIndex(cov, g.glyph) != nil end)
          else
            true
          end

        # do we match lookahead?
        laMatches =
          if lookahead > 0 do
            output
            |> Enum.take(lookahead)
            |> Enum.zip(laCoverage)
            |> Enum.all?(fn {g, cov} -> findCoverageIndex(cov, g.glyph) != nil end)
          else
            true
          end

        if inputMatches and backMatches and laMatches do
          %{g | glyph: Enum.at(subst, coverloc)}
        else
          g
        end
      end

    output = [replacement | output]

    applyReverseChainingContext(
      btCoverage,
      coverage,
      laCoverage,
      subst,
      lookups,
      preceding,
      output
    )
  end

  # handle coverage-based format for context chaining
  defp applyChainingContextSub3(_btCoverage, _coverage, _laCoverage, _subst, _, [], _pga, output),
    do: output

  defp applyChainingContextSub3(
         btCoverage,
         coverage,
         laCoverage,
         substRecords,
         lookups,
         [g | glyphs],
         tag,
         output
       ) do
    backtrack = length(btCoverage)
    inputExtra = length(coverage) - 1
    lookahead = length(laCoverage)

    oo =
      cond do
        # not enough backtracking or lookahead to even attempt match
        length(output) < backtrack or length(glyphs) < lookahead + inputExtra ->
          [g]

        # filter to only process when tag applies for current glyph
        tag != nil and g.tag != tag ->
          [g]

        true ->
          # do we match the input
          input = [g] ++ Enum.take(glyphs, inputExtra)

          inputMatches =
            input
            |> Enum.zip(coverage)
            |> Enum.all?(fn {g, cov} -> findCoverageIndex(cov, g.glyph) != nil end)

          # do we match backtracking?
          backMatches =
            if backtrack > 0 do
              output
              |> Enum.reverse()
              |> Enum.take(backtrack)
              |> Enum.zip(btCoverage)
              |> Enum.all?(fn {g, cov} -> findCoverageIndex(cov, g.glyph) != nil end)
            else
              true
            end

          # do we match lookahead
          laMatches =
            if lookahead > 0 do
              glyphs
              |> Enum.drop(inputExtra)
              |> Enum.take(lookahead)
              |> Enum.zip(laCoverage)
              |> Enum.all?(fn {g, cov} -> findCoverageIndex(cov, g.glyph) != nil end)
            else
              true
            end

          if inputMatches and backMatches and laMatches do
            replaced =
              substRecords
              |> Enum.reduce(input, fn {inputLoc, lookupIndex}, acc ->
                candidate = Enum.at(acc, inputLoc)
                lookup = Enum.at(lookups, lookupIndex)
                [replacement | _] = parse_and_apply(lookup, nil, lookups, nil, [candidate])
                List.replace_at(acc, inputLoc, replacement)
              end)

            replaced
          else
            [g]
          end
      end

    output = output ++ oo

    applyChainingContextSub3(
      btCoverage,
      coverage,
      laCoverage,
      substRecords,
      lookups,
      glyphs,
      tag,
      output
    )
  end

  # given a glyph, find out the coverage index (can be nil)
  defp findCoverageIndex(cov, g) when is_integer(hd(cov)) do
    Enum.find_index(cov, fn i -> i == g end)
  end

  defp findCoverageIndex(cov, g) when is_tuple(hd(cov)) do
    r = Enum.find(cov, fn {f, l, _} -> f <= g and g <= l end)

    if r != nil do
      {s, _, i} = r
      i + g - s
    else
      nil
    end
  end

  # catch-all
  defp findCoverageIndex(_cov, _g) do
    nil
  end

  defp classifyGlyph(_g, nil), do: 0

  defp classifyGlyph(g, classes) when is_map(classes) do
    Map.get(classes, g, 0)
  end

  defp classifyGlyph(g, ranges) do
    r = Enum.find(ranges, fn {f, l, _} -> f <= g and g <= l end)
    # if no match, class 0
    if r == nil do
      0
    else
      {_, _, class} = r
      class
    end
  end

  # TODO: does this make sense in regard to GSUB? indices might not be sufficient if not one-to-one SUB! 
  def filter_glyphs(glyphs, flag, gdef, mfs) do
    skipped =
      glyphs
      |> Enum.with_index()
      |> Enum.filter(fn {g, _} -> should_skip_glyph?(g.glyph, flag, gdef, mfs) end)

    filtered =
      glyphs
      |> Enum.reject(fn g -> should_skip_glyph?(g.glyph, flag, gdef, mfs) end)

    {filtered, skipped}
  end

  def unfilter_glyphs(glyphs, skipped) do
    # Logger.debug("unfilter #{inspect glyphs}, #{inspect skipped}")
    skipped
    |> Enum.reduce(glyphs, fn {g, i}, acc -> List.insert_at(acc, i, g) end)
  end

  # returns true when the lookup flag is set to a value
  def should_skip_glyph?(g, flag, gdef, mfs) do
    # decompose the flag
    <<attachmentType::8, _::3, useMarkFilteringSet::1, ignoreMark::1, ignoreLig::1, ignoreBase::1,
      _rtl::1>> = <<flag::16>>

    cond do
      # short circuit - if no flags, we aren't skipping anything
      flag == 0 ->
        false

      # skip if ignore is set and we match the corresponding GDEF class
      ignoreBase == 1 and classifyGlyph(g, gdef.classes) == 1 ->
        true

      ignoreLig == 1 and classifyGlyph(g, gdef.classes) == 2 ->
        true

      ignoreMark == 1 and classifyGlyph(g, gdef.classes) == 3 ->
        true

      # skip if mark not in mark glyph set
      useMarkFilteringSet == 1 and classifyGlyph(g, gdef.classes) == 3 and
          findCoverageIndex(g, Enum.at(gdef.mark_sets, mfs)) == nil ->
        true

      # skip if mark doesn't match a non-zero attachment type
      attachmentType != 0 and classifyGlyph(g, gdef.classes) == 3 and
          classifyGlyph(g, gdef.attachments) != attachmentType ->
        true

      # default is DO NOT SKIP
      true ->
        false
    end
  end
end
