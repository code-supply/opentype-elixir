defmodule OpenType.Substitutions do
  alias OpenType.Parser
  require Logger

  # ==============================================
    # GSUB glyph substitutions
    # Used for ligatures, swashes, alternate forms
    # if a lookup type is as-yet unsupported
    # simply passes through the input
  # ==============================================
  # GSUB 1 -- single substitution (one-for-one)
  def applyLookupGSUB({1, _flag, table, _mfs}, _gdef, _lookups, tag, {glyphs, pga}) do
    <<format::16, covOff::16, rest::binary>> = table
    coverage = Parser.parseCoverage(Parser.subtable(table, covOff))
    replace = case format do
      1 ->
        <<delta::16, _::binary>> = rest
        fn g -> applySingleSub(g, coverage, delta) end
      2 ->
        <<nGlyphs::16, ga::binary-size(nGlyphs)-unit(16), _::binary>> = rest
        replacements = for << <<x::16>> <- ga >>, do: x
        fn g -> applySingleSub(g, coverage, replacements) end
      _ ->
        Logger.debug "Unknown GSUB 1 subtable format #{format}"
        fn g -> g end
    end
    output = if tag != nil do
      IO.puts "GSUB 1 per-glyph #{tag} lookup"
      glyphs
      |> Enum.with_index
      |> Enum.map(fn {x, i} -> {x, Enum.at(pga, i)} end)
      |> Enum.map(fn {g, assignment} -> if assignment == tag, do: replace.(g), else: g end)
    else
      Enum.map(glyphs, replace)
    end
    {output, pga}
  end

  #GSUB 2 - multiple substitution (expand one glyph into several)
  def applyLookupGSUB({2, _flag, table, _mfs}, _gdef, _, tag, {glyphs, pga}) do
    <<_format::16, covOff::16, nSeq::16, subOff::binary-size(nSeq)-unit(16), _::binary>> = table
    coverage = Parser.parseCoverage(Parser.subtable(table, covOff))
    # sequence tables
    seqOffsets = for << <<x::16>> <- subOff >>, do: x

    # sequence table structure identical to alt table
    sequences = Enum.map(seqOffsets, fn seqOffset -> Parser.parseAlts(table, seqOffset) end)
    output = if tag != nil do
      glyphs
      |> Enum.with_index
      |> Enum.map(fn {x, i} -> {x, Enum.at(pga, i)} end)
      |> Enum.map(fn {g, assignment} -> if assignment == tag, do: applyMultiSub(g, coverage, sequences), else: g end)
    else
      glyphs
      |> Enum.map(fn g -> applyMultiSub(g, coverage, sequences) end)
    end

    #ensure we preserve the per-glyph tags during expansion
    pga_out = if pga do
      output
         |> Enum.with_index
         |> Enum.map(fn {x, i} -> {x, Enum.at(pga, i)} end)
         |> Enum.map(fn {g, assignment} -> if is_list(g), do: List.duplicate(assignment, length(g)), else: assignment  end)
         |> List.flatten
    else
      pga
    end

    {List.flatten(output), pga_out}
  end

  # GSUB type 3 -- alternate substitution (one-for-one)
  def applyLookupGSUB({3, _flag, _offsets, table, _mfs}, _gdef, _, tag, pga, glyphs) do
    <<1::16, covOff::16, nAltSets::16, aoff::binary-size(nAltSets)-unit(16), _::binary>> = table
    coverage = Parser.parseCoverage(Parser.subtable(table, covOff))
    # alternate set tables
    altOffsets = for << <<x::16>> <- aoff >>, do: x
    alts = Enum.map(altOffsets, fn altOffset -> Parser.parseAlts(table, altOffset) end)
    # TODO: seems like there's a way in unicode to specify alt??
    # More research required, for now substitute a random alt
    if tag != nil do
      IO.puts "GSUB 3 per-glyph #{tag} lookup"
      glyphs
      |> Enum.with_index
      |> Enum.map(fn {x, i} -> {x, Enum.at(pga, i)} end)
      |> Enum.map(fn {g, assignment} -> if assignment == tag, do: applyRandomAlt(g, coverage, alts), else: g end)
    end
    Enum.map(glyphs, fn g -> applyRandomAlt(g, coverage, alts) end)
  end

  # GSUB type 4 -- ligature substition (single glyph replaces multiple glyphs)
  def applyLookupGSUB({4, _flag, table, _mfs}, _gdef, _, tag, _pga, input) do
    #parse ligature table
    <<1::16, covOff::16, nLigSets::16, lsl::binary-size(nLigSets)-unit(16), _::binary>> = table
    # ligature set tables
    ls = for << <<x::16>> <- lsl >>, do: x
    # coverage table
    coverage = Parser.parseCoverage(Parser.subtable(table, covOff))
    # ligatures
    ligaOff = Enum.map(ls, fn lsOffset -> Parser.parseLigatureSet(table, lsOffset) end)
    if tag != nil do
      IO.puts "GSUB 4 per-glyph #{tag} lookup"
    end
    applyLigature(coverage, ligaOff, input, [])
  end

  #GSUB type 5 -- contextual substitution
  def applyLookupGSUB({5, _flag, table, _mfs}, _gdef, lookups, tag, _pga, glyphs) do
    <<format::16, details::binary>> = table
    if tag != nil do
      IO.puts "GSUB 5 per-glyph #{tag} lookup"
    end
    output = case format do
      1 ->
        <<covOff::16, 
          nRulesets::16, 
          srsOff::binary-size(nRulesets)-unit(16),
          _::binary>> = details
        coverage = Parser.parseCoverage(Parser.subtable(table, covOff))
        srs = for << <<offset::16>> <- srsOff >>, do: Parser.subtable(table, offset)
        rulesets = srs
                   |> Enum.map(fn ruleset -> 
                      <<nRules::16, srOff::binary-size(nRules)-unit(16), _::binary>> = ruleset
                      rules = for << <<offset::16>> <- srOff >>, do: Parser.subtable(ruleset, offset)
                      rules |> Enum.map(&Parser.parseContextSubRule1(&1))
                      end)
        applyContextSub1(coverage, rulesets, lookups, glyphs, [])
      2 ->
        <<covOff::16, 
          classDefOff::16,
          nRulesets::16, 
          srsOff::binary-size(nRulesets)-unit(16),
          _::binary>> = details
        coverage = Parser.parseCoverage(Parser.subtable(table, covOff))
        classes = Parser.parseGlyphClass(Parser.subtable(table, classDefOff))
        srs = for << <<offset::16>> <- srsOff >>, do: if offset != 0, do: Parser.subtable(table, offset), else: nil
        rulesets = srs
                   |> Enum.map(fn ruleset -> 
                      if ruleset != nil do
                        <<nRules::16, srOff::binary-size(nRules)-unit(16), _::binary>> = ruleset
                        rules = for << <<offset::16>> <- srOff >>, do: Parser.subtable(ruleset, offset)
                        rules |> Enum.map(&Parser.parseContextSubRule1(&1))
                      else
                        nil
                      end
                      end)
        applyContextSub2(coverage, rulesets, classes, lookups, glyphs, [])
      3 ->
        Logger.debug "GSUB 5.3 - contextual substitution"
        glyphs
      _ ->
        Logger.debug "GSUB 5 - contextual substitution format #{format}"
        glyphs
    end
    output
  end

  #GSUB type 6 -- chained contextual substitution
  def applyLookupGSUB({6, flag, table, mfs}, gdef, lookups, tag, _pga, glyphs) do
    if tag != nil do
      IO.puts "GSUB 6 per-glyph #{tag} lookup"
    end
    <<format::16, details::binary>> = table
    output = case format do
      1 ->
        Logger.debug "GSUB 6.1 - chained substitution"
        glyphs
      2 ->
        <<covOff::16, btClassOff::16, inputClassOff::16, laClassOff::16,
          nClassSets::16, classSetOff::binary-size(nClassSets)-unit(16),
          _::binary>> = details
        coverage = Parser.parseCoverage(Parser.subtable(table, covOff))
        btClasses = Parser.parseGlyphClass(Parser.subtable(table, btClassOff))
        inputClasses = Parser.parseGlyphClass(Parser.subtable(table, inputClassOff))
        laClasses = Parser.parseGlyphClass(Parser.subtable(table, laClassOff))
        srs = for << <<offset::16>> <- classSetOff >>, do: if offset != 0, do: Parser.subtable(table, offset), else: nil
        rulesets =  srs
                    |> Enum.map(fn ruleset ->
                      if ruleset != nil do
                        <<nRules::16, srOff::binary-size(nRules)-unit(16), _::binary>> = ruleset
                        rules = for << <<offset::16>> <- srOff >>, do: Parser.subtable(ruleset, offset)
                        rules |> Enum.map(&Parser.parseChainedSubRule2(&1))
                      else
                        nil
                      end
                    end)
        applyChainingContextSub2(coverage, rulesets, {btClasses, inputClasses, laClasses}, lookups, glyphs, [])
      3 ->
        <<backtrackCount::16, backoff::binary-size(backtrackCount)-unit(16),
          inputCount::16, inputOff::binary-size(inputCount)-unit(16),
          lookaheadCount::16, lookaheadOff::binary-size(lookaheadCount)-unit(16),
          substCount::16, substRecs::binary-size(substCount)-unit(32),
          _::binary>> = details
        backOffsets = for << <<x::16>> <- backoff >>, do: x
        btCoverage = Enum.map(backOffsets, fn covOff -> Parser.parseCoverage(Parser.subtable(table, covOff)) end)
        inputOffsets = for << <<x::16>> <- inputOff >>, do: x
        coverage = Enum.map(inputOffsets, fn covOff -> Parser.parseCoverage(Parser.subtable(table, covOff)) end)
        lookaheadOffsets = for << <<x::16>> <- lookaheadOff >>, do: x
        laCoverage = Enum.map(lookaheadOffsets, fn covOff -> Parser.parseCoverage(Parser.subtable(table, covOff)) end)
        substRecords = for << <<x::16, y::16>> <- substRecs >>, do: {x, y}
        # context = {btCoverage, coverage, laCoverage, substRecords}
        {f, skipped} = filter_glyphs(glyphs, flag, gdef, mfs)
        replaced = applyChainingContextSub3(btCoverage, coverage, laCoverage, substRecords, lookups, f, [])
        unfilter_glyphs(replaced, skipped)
      _ ->
        Logger.debug "GSUB 6 - chaining substitution format #{format}"
        glyphs
    end
    output
  end

  #GSUB type 7 -- extended table (handled below as it contains offset argument)

  #GSUB type 8 -- reverse chained contextual substitution
  def applyLookupGSUB({8, _flag, _table, _mfs}, _gdef, _, _tag, _pga, glyphs) do
    Logger.debug "GSUB 8 - reverse chaining substitution"
    glyphs
  end

  #unhandled type; log and leave input untouched
  def applyLookupGSUB({type, _flag, _table, _mfs}, _gdef, _, _tag, _pga, glyphs) do
    Logger.debug "Unknown GSUB lookup type #{type}"
    glyphs
  end

  #overload
  def applyLookupGSUB({type, flag, table, mfs}, gdef, lookups, tag, {glyphs, pga}) do
    out = applyLookupGSUB({type, flag, table, mfs}, gdef, lookups, tag, pga, glyphs)
    {out, pga}
  end


  # GSUB type 7 -- extended table
  def applyLookupGSUB({7, flag, offsets, table, mfs}, gdef, lookups, tag, {glyphs, pga}) do
    subtables = offsets
            |> Enum.map(fn x ->
            <<1::16, lt::16, off::32>> = binary_part(table, x, 8)
            {lt, Parser.subtable(table, x + off)}
              end)
    #for each subtable
    Enum.reduce(subtables, {glyphs, pga}, fn ({type, tbl}, input) -> applyLookupGSUB({type, flag, tbl, mfs}, gdef, lookups, tag, input) end)
  end
  def applyLookupGSUB({type, flag, offsets, table, mfs}, gdef, lookups, tag, {glyphs, pga}) do
    #for each subtable
    Enum.reduce(offsets, {glyphs, pga}, fn (offset, input) -> applyLookupGSUB({type, flag, Parser.subtable(table, offset), mfs}, gdef, lookups, tag, input) end)
  end

  defp applySingleSub(g, coverage, delta) when is_integer(delta) do
    coverloc = findCoverageIndex(coverage, g)
    if coverloc != nil, do: g + delta, else: g
  end
  defp applySingleSub(g, coverage, replacements) do
    coverloc = findCoverageIndex(coverage, g)
    if coverloc != nil, do: Enum.at(replacements, coverloc), else: g
  end
  defp applyMultiSub(g, coverage, seq) do
    coverloc = findCoverageIndex(coverage, g)
    if coverloc != nil do
      Enum.at(seq, coverloc)
    else
      g
    end
  end


  defp applyRandomAlt(g, coverage, alts) do
    coverloc = findCoverageIndex(coverage, g)
    if coverloc != nil do
      candidates = Enum.at(alts, coverloc)
      Enum.random(candidates)
    else
      g
    end
  end
  defp applyLigature(_coverage, _ligatures, [], output), do: output
  defp applyLigature(coverage, ligatures, [g | glyphs], output) do
    # get the index of a ligature set that might apply
    coverloc = findCoverageIndex(coverage, g)
    {output, glyphs} = if coverloc != nil do
      # find first match in this ligature set (if any)
      # TODO: flag might mean we need to filter ignored categories
      # ie; skip marks
      lig = Enum.find(Enum.at(ligatures, coverloc), fn {_replacement, match} -> Enum.take(glyphs, length(match)) == match end)
      if lig != nil do
        # replace the current glyph
        {rep, m} = lig
        # skip over any matched glyphs
        # TODO: handle flags correctly
        # probably want to prepend earlier ignored glyphs to remaining
        remaining = Enum.slice(glyphs, length(m), length(glyphs))
        {output ++ [rep], remaining}
      else
        {output ++ [g], glyphs}
      end
    else
      {output ++ [g], glyphs}
    end
    applyLigature(coverage, ligatures, glyphs, output)
  end

  defp applyContextSub1(_coverage, _rulesets, _lookups, [], output), do: output
  defp applyContextSub1(coverage, rulesets, lookups, [g | glyphs], output) do
    coverloc = findCoverageIndex(coverage, g)
    {o, glyphs} = if coverloc != nil do
      ruleset = Enum.at(rulesets, coverloc)
      #find first match in this ruleset
      # TODO: flag might mean we need to filter ignored categories
      # ie; skip marks
      rule = Enum.find(ruleset, fn {input, _} -> Enum.take(glyphs, length(input)) == input end)
      if rule != nil do
        # Logger.debug "GSUB5.1 rule = #{inspect rule}"
        {matched, substRecords} = rule
        input = [g | matched]
        replaced = substRecords
        |> Enum.reduce(input, fn {inputLoc, lookupIndex}, acc ->
          candidate = Enum.at(acc, inputLoc)
          lookup = Enum.at(lookups, lookupIndex)
          {[replacement | _], _} = applyLookupGSUB(lookup, nil, lookups, nil, {[candidate], nil})
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
    applyContextSub1(coverage, rulesets, lookups, glyphs, output)
  end

  # class-based context
  defp applyContextSub2(_coverage, _rulesets, _classes, _lookups, [], output), do: output
  defp applyContextSub2(coverage, rulesets, classes, lookups, [g | glyphs], output) do
    coverloc = findCoverageIndex(coverage, g)
    ruleset = Enum.at(rulesets, classifyGlyph(g, classes))
    {o, glyphs} = if coverloc != nil  and ruleset != nil do
      #Logger.debug "GSUB5.2 rule = #{inspect ruleset}"
      #find first match in this ruleset
      # TODO: flag might mean we need to filter ignored categories
      # ie; skip marks
      rule = Enum.find(ruleset, fn {input, _} ->
                        candidates = glyphs
                          |> Enum.take(length(input))
                          |> Enum.map(fn g -> classifyGlyph(g, classes) end)
                         candidates == input 
                       end)
      if rule != nil do
        {matched, substRecords} = rule
        input = [g | Enum.take(glyphs, length(matched))]
        replaced = substRecords
        |> Enum.reduce(input, fn {inputLoc, lookupIndex}, acc ->
          candidate = Enum.at(acc, inputLoc)
          lookup = Enum.at(lookups, lookupIndex)
          {[replacement | _], _} = applyLookupGSUB(lookup, nil, lookups, nil, {[candidate], nil})
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
  defp applyChainingContextSub2(coverage, rulesets, {btClasses, inputClasses, laClasses}, lookups, [g | glyphs], output) do
    coverloc = findCoverageIndex(coverage, g)
    ruleset = Enum.at(rulesets, classifyGlyph(g, inputClasses))
    {o, glyphs} = if coverloc != nil  and ruleset != nil do
      # find first match
      rule = Enum.find(ruleset, fn rule -> doesCCS2match(rule, {btClasses, inputClasses, laClasses}, output, g, glyphs) end)
      # apply substitutions to input
      if rule != nil do
        {_,im,_,substRecords} = rule
        inputExtra = length(im) - 1
        input = [g] ++ Enum.take(glyphs, inputExtra)
        replaced = substRecords
        |> Enum.reduce(input, fn {inputLoc, lookupIndex}, acc ->
          candidate = Enum.at(acc, inputLoc)
          lookup = Enum.at(lookups, lookupIndex)
          {[replacement | _], _} = applyLookupGSUB(lookup, nil, lookups, nil, {[candidate], nil})
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
    applyChainingContextSub2(coverage, rulesets, {btClasses, inputClasses, laClasses}, lookups, glyphs, output)
  end

  defp doesCCS2match(rule, {btClasses, inputClasses, laClasses}, output, g, glyphs) do
    {btMatch, inputMatch, laMatch, _} = rule
    backtrack = length(btMatch)
    inputExtra = length(inputMatch) - 1
    lookahead = length(laMatch)

    #not enough backtracking or lookahead to even attempt match
    if length(output) < backtrack or length(glyphs) < lookahead + inputExtra do
      false
    else
      #do we match the input
      input = [g] ++ Enum.take(glyphs, inputExtra)
      inputMatches = input
                     |> Enum.zip(inputMatch)
                     |> Enum.all?(fn {g, class} -> classifyGlyph(g, inputClasses) == class end)

      #do we match backtracking?
      backMatches = if backtrack > 0 do
        output
        |> Enum.reverse
        |> Enum.take(backtrack)
        |> Enum.zip(btMatch)
        |> Enum.all?(fn {g, class} -> classifyGlyph(g, btClasses) == class end)
      else
        true
      end

      #do we match lookahead
      laMatches = if lookahead > 0 do
        glyphs
        |> Enum.drop(inputExtra)
        |> Enum.take(lookahead)
        |> Enum.zip(laMatch)
        |> Enum.all?(fn {g, class} -> classifyGlyph(g, laClasses) == class end)
      else
        true
      end

      inputMatches and backMatches and laMatches
    end
  end

  # handle coverage-based format for context chaining
  defp applyChainingContextSub3(_btCoverage, _coverage, _laCoverage, _subst, _, [], output), do: output
  defp applyChainingContextSub3(btCoverage, coverage, laCoverage, substRecords, lookups, [g | glyphs], output) do
    #TODO: Need to handle skipped glyphs


    backtrack = length(btCoverage)
    inputExtra = length(coverage) - 1
    lookahead = length(laCoverage)
    #not enough backtracking or lookahead to even attempt match
    oo = if length(output) < backtrack or length(glyphs) < lookahead + inputExtra do
      [g]
    else

      #do we match the input
      input = [g] ++ Enum.take(glyphs, inputExtra)
      inputMatches = input
                     |> Enum.zip(coverage)
                     |> Enum.all?(fn {g, cov} -> findCoverageIndex(cov, g) != nil end)

      #do we match backtracking?
      backMatches = if backtrack > 0 do
        output
        |> Enum.reverse
        |> Enum.take(backtrack)
        |> Enum.zip(btCoverage)
        |> Enum.all?(fn {g, cov} -> findCoverageIndex(cov, g) != nil end)
      else
        true
      end

      #do we match lookahead
      laMatches = if lookahead > 0 do
        glyphs
        |> Enum.drop(inputExtra)
        |> Enum.take(lookahead)
        |> Enum.zip(laCoverage)
        |> Enum.all?(fn {g, cov} -> findCoverageIndex(cov, g) != nil end)
      else
        true
      end

      if inputMatches and backMatches and laMatches do
        replaced = substRecords
        |> Enum.reduce(input, fn {inputLoc, lookupIndex}, acc ->
          candidate = Enum.at(acc, inputLoc)
          lookup = Enum.at(lookups, lookupIndex)
          {[replacement | _], _} = applyLookupGSUB(lookup, nil, lookups, nil, {[candidate], nil})
          List.replace_at(acc, inputLoc, replacement)
        end)
        replaced
      else
        [g]
      end

    end
    output = output ++ oo
    applyChainingContextSub3(btCoverage, coverage, laCoverage, substRecords, lookups, glyphs, output)
  end




  # given a glyph, find out the coverage index (can be nil)
  defp findCoverageIndex(cov, g) when is_integer(hd(cov)) do
    Enum.find_index(cov, fn i -> i == g end)
  end
  defp findCoverageIndex(cov, g) when is_tuple(hd(cov)) do
    r = Enum.find(cov, fn {f,l,_} -> f <= g and g <= l end)
    if r != nil do
      {s,_,i} = r
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
    r = Enum.find(ranges, fn {f,l,_} -> f <= g and g <= l end)
    # if no match, class 0
    if r == nil do
      0
    else
      {_,_,class} = r
      class
    end
  end

  #TODO: does this make sense in regard to GSUB? indices might not be sufficient if not one-to-one SUB! 
  def filter_glyphs(glyphs, flag, gdef, mfs) do
    skipped = glyphs
              |> Enum.with_index
              |> Enum.filter(fn {g, _} -> should_skip_glyph(g, flag, gdef, mfs) end)

    filtered = glyphs
              |> Enum.filter(fn g -> !should_skip_glyph(g, flag, gdef, mfs) end)
    {filtered, skipped}
  end

  def unfilter_glyphs(glyphs, skipped) do
    #Logger.debug("unfilter #{inspect glyphs}, #{inspect skipped}")
    skipped
    |> Enum.reduce(glyphs, fn {g, i}, acc -> List.insert_at(acc, i, g) end)
  end


  # returns true when the lookup flag is set to a value
  def should_skip_glyph(g, flag, gdef, mfs) do
    # decompose the flag
    <<attachmentType::8, _::3, useMarkFilteringSet::1, ignoreMark::1, ignoreLig::1, ignoreBase::1, _rtl::1>> = <<flag::16>>

    if useMarkFilteringSet != 0 do
      Logger.debug "MFS #{mfs}"
    end

    cond do
      # short circuit - if no flags, we aren't skipping anything
      flag == 0 -> false
      # skip if ignore is set and we match the corresponding GDEF class
      ignoreBase == 1 and classifyGlyph(g, gdef.classes) == 1 -> true
      ignoreLig  == 1 and classifyGlyph(g, gdef.classes) == 2 -> true
      ignoreMark == 1 and classifyGlyph(g, gdef.classes) == 3 -> true
      # skip if mark not in mark glyph set
      useMarkFilteringSet == 1 and classifyGlyph(g, gdef.classes) == 3 and findCoverageIndex(g, Enum.at(gdef.mark_sets, mfs)) == nil -> true
      # skip if mark doesn't match a non-zero attachment type
      attachmentType != 0  and classifyGlyph(g, gdef.classes) == 3 and classifyGlyph(g, gdef.attachments) != attachmentType -> true
      # default is DO NOT SKIP
      true -> false
    end
  end
end
