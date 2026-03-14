--[[--
Test Document Generator for Piper TTS Benchmark
Generates a multi-page document with varied paragraph structures
to stress-test different synthesis strategies.

@module testdoc
--]]

local TestDoc = {}

-- ── Page content ─────────────────────────────────────────────────────
-- Each "page" is an array of paragraphs. Paragraphs contain sentences
-- of different lengths to exercise batching and chunking strategies.

TestDoc.pages = {
    -- Page 1: Short conversational sentences (dialogue-heavy)
    {
        "The old man looked up from his book. \"Did you hear that?\" he asked. She shook her head slowly.",
        "\"It sounded like thunder,\" he continued, peering out the window. The sky was perfectly clear.",
        "\"You're imagining things again,\" she said with a gentle smile. He returned to his reading.",
        "A moment passed. Then another rumble, deeper this time. They both froze.",
        "\"There,\" he whispered. \"Tell me you heard that.\"",
        "She had. The teacup in her hand trembled slightly. Outside, the birds had gone silent.",
    },

    -- Page 2: Medium-length narrative prose
    {
        "The village of Thornbury had existed for seven hundred years, nestled in the gentle fold between two limestone ridges that ran parallel to the coast. Its church spire, visible for miles around, served as a landmark for sailors navigating the treacherous waters of the bay.",
        "In the center of the village stood an ancient oak tree, its trunk so wide that five men holding hands could barely encircle it. Local legend held that the tree had been planted by the first settlers, though no one could say for certain whether this was true.",
        "Every autumn, the villagers gathered beneath its spreading branches for the harvest festival. Tables were set end to end along the cobblestone square, laden with fresh bread, roasted meats, and pies filled with apples from the surrounding orchards.",
        "This year, however, the festival would be different. The war had taken many of the young men, and those who remained bore the quiet weight of uncertainty on their shoulders.",
    },

    -- Page 3: Long complex sentences (academic/technical style)
    {
        "The relationship between computational complexity and real-time audio synthesis presents a fundamental challenge for embedded systems, particularly when neural network architectures are deployed on processors with limited floating-point throughput and constrained memory hierarchies.",
        "Contemporary text-to-speech systems based on transformer architectures typically require between fifty and two hundred million parameters, with each inference pass involving matrix multiplications across multiple attention heads that scale quadratically with sequence length.",
        "On a Cortex-A9 processor clocked at one gigahertz, a single forward pass through even a compact voice model may require three to fifteen seconds per phoneme group, yielding a synthesis-to-playback ratio well below unity; that is, the system generates audio slower than real-time playback speed.",
        "Several optimization strategies exist to mitigate this bottleneck, including quantization of model weights from thirty-two-bit floating point to eight-bit integers, pruning of redundant attention heads, and pipelining of inference across multiple process instances to exploit instruction-level parallelism even on single-core architectures.",
    },

    -- Page 4: Very short sentences and fragments
    {
        "Stop. Listen. Nothing.",
        "The door creaked open. Darkness beyond. Cold air rushed in.",
        "She stepped forward. One step. Then another. The floor groaned beneath her weight.",
        "A light flickered ahead. Candle flame. Orange and warm. It danced in the draft from the open door behind her.",
        "\"Hello?\" she called out. No answer came. Only the echo of her own voice returning from the stone walls.",
        "She waited. Silence stretched like taffy. Thick and slow and suffocating.",
        "Then footsteps. Not hers. Coming from somewhere deeper inside.",
        "She held her breath.",
    },

    -- Page 5: Mixed dialogue and description with punctuation variety
    {
        "Professor Whitfield adjusted his spectacles, a habit he'd developed over forty years of lecturing; it gave him a moment to collect his thoughts. \"The problem, you see, is not merely one of engineering,\" he began, pacing before the chalkboard. \"It is a problem of philosophy.\"",
        "His students, perhaps two dozen in number, sat in various states of attention: some leaned forward eagerly, pencils poised; others gazed out the tall windows at the autumn leaves drifting across the quad; and one, in the back row, was quite certainly asleep.",
        "\"Consider this,\" Whitfield continued, tapping his chalk against the board for emphasis. \"When we synthesize speech from text, we are not simply converting symbols to sounds. We are making choices, hundreds of them per second, about emphasis, rhythm, and emotion. These are fundamentally human decisions.\"",
        "A hand shot up near the front. \"But Professor, doesn't the neural network learn those patterns from training data?\" asked Chen, one of his more promising graduate students.",
        "\"Excellent question!\" Whitfield exclaimed, his eyes brightening. \"It learns correlations, yes. Patterns of prosody associated with particular textual features: questions rise, declarations fall, parenthetical remarks accelerate. But does it understand them? That, my friends, is the crux of the matter.\"",
    },

    -- Page 6: Numbers, abbreviations, and technical content
    {
        "The Kobo Clara 2E features an NXP i.MX6 SoloLite processor running at 1 GHz, with 256 MB of RAM and 16 GB of internal storage. The display measures 6 inches diagonally with a resolution of 1448 by 1072 pixels, yielding a pixel density of approximately 300 PPI.",
        "Battery capacity is rated at 1500 mAh, which under normal reading conditions provides roughly 6 to 8 weeks of use between charges. The USB-C port supports both charging at 5V/1A and data transfer for sideloading content.",
        "For TTS workloads, the critical bottleneck is the single-core ARM Cortex-A9 running at 1 GHz without hardware floating-point acceleration in the neural network inference path. Memory bandwidth, measured at approximately 800 MB/s for the DDR3 interface, is sufficient but the cache hierarchy, with only 32 KB L1 and 256 KB L2, creates frequent stalls during matrix operations.",
        "In our tests, the en_US-danny-low model, which has approximately 15.7 million parameters stored in a 63 MB ONNX file, achieves a throughput of roughly 2,100 to 3,400 phonemes per minute, corresponding to 25 to 40 words per minute of synthesized speech.",
    },

    -- Page 7: Emotional and varied-pace prose
    {
        "She ran. Not the careful, measured jog of her morning routine, but a desperate, lunging sprint through streets that blurred past her like watercolors left in the rain. Her lungs burned. Her legs screamed. But she could not stop, would not stop, because behind her, gaining with every heartbeat, was the sound of something that should not exist.",
        "Three blocks. Two blocks. One. The apartment building loomed ahead, its familiar brick facade a beacon of safety in a world gone suddenly, terrifyingly wrong. She hit the front steps at full speed, nearly falling, catching herself on the iron railing with a grip that would leave bruises.",
        "Keys. Where were her keys? Frantically, she dug through her pockets, her fingers numb and clumsy with adrenaline. Left pocket. No. Right pocket. No, no, no. Jacket, inner pocket, yes, there, the cold metal shape of salvation.",
        "The lock clicked. The door swung open. She threw herself inside, slammed it shut, and turned the deadbolt with shaking hands.",
        "Silence. Beautiful, ordinary, blessed silence.",
        "She slid down the door and sat on the floor, chest heaving, tears streaming down her face, and laughed. A wild, hysterical laugh that echoed through the empty hallway and told her, unequivocally, that she was alive.",
    },

    -- Page 8: Structured instructional content
    {
        "To configure the text-to-speech benchmark, follow these steps carefully. First, ensure that the Piper binary and at least one voice model are present in the expected directory. The default location is the piper subdirectory of the plugin folder.",
        "Second, verify that the model's companion JSON configuration file exists alongside the ONNX model file. This file contains the sample rate, phoneme mapping, and speaker information that Piper requires for synthesis.",
        "Third, run the initialization script with the appropriate flags. Use the verbose flag for detailed timing output, or the quiet flag if you only need the summary statistics. The benchmark will synthesize each page of the test document using every registered strategy.",
        "Fourth, examine the results in the output directory. Each strategy produces a separate report file containing per-sentence timing data, aggregate statistics, and any errors encountered during synthesis. Compare the realtime factor across strategies to identify the most efficient approach.",
        "Finally, note that the first run of each strategy may show inflated cold-start times due to filesystem caching effects. For reliable comparisons, run each strategy at least twice and discard the first result, or ensure the filesystem cache is cleared between runs using the provided flush script.",
    },

    -- Page 9: Poetry and rhythm-heavy text
    {
        "The fog comes on little cat feet. It sits looking over harbor and city on silent haunches and then moves on. These words, penned by Carl Sandburg more than a century ago, capture something essential about the nature of change: it arrives quietly, settles in without announcement, and departs before we've fully registered its presence.",
        "In the garden, autumn was performing its annual slow-motion fireworks display. The maples had gone first, as they always did, erupting in scarlet and gold that made the whole hillside look as though it were ablaze. Then came the oaks, more restrained, their leaves turning a deep, dignified bronze. Last of all, the beeches surrendered their green in reluctant stages, passing through yellow into a pale copper that caught the low November sunlight like hammered metal.",
        "There is a quality to late afternoon light in autumn that exists at no other time of year. It comes in at a sharp angle, golden and warm, casting long shadows that stretch across the grass like dark rivers flowing toward the east. Everything it touches seems to glow from within, as though the world itself has been set on a slow, gentle fire that gives warmth without consuming.",
    },

    -- Page 10: Stress test - very long paragraph
    {
        "The history of text-to-speech technology stretches back further than most people realize, beginning not with computers but with mechanical devices that attempted to replicate the human vocal tract through physical means. In 1779, Christian Kratzenstein built resonating tubes that could produce the five long vowel sounds when activated by vibrating reeds, and in 1791, Wolfgang von Kempelen constructed a more elaborate machine with a bellows for lungs, a reed for the vocal cords, and a leather tube shaped by hand to form different vowels and consonants. These early efforts established the fundamental principle that speech is, at its core, a physical process that can be analyzed and reproduced through understanding of acoustics and articulatory phonetics. The first electronic speech synthesizer, the Voder, was demonstrated by Homer Dudley at the 1939 World's Fair, requiring a skilled operator to play the machine like a musical instrument, pressing keys and manipulating a pedal to produce recognizable, if somewhat eerie, human speech. The development of digital computers in the mid-twentieth century opened entirely new approaches, leading to formant synthesis systems like Dennis Klatt's DECtalk, which powered the voice of Stephen Hawking for decades, and later to concatenative synthesis, which assembled speech from pre-recorded fragments of human voice. The neural revolution of the 2010s, beginning with WaveNet and continuing through Tacotron, VITS, and Piper, has brought us to the current era where synthesized speech can be virtually indistinguishable from natural human voice, at least when running on hardware with sufficient computational resources to perform inference in real time.",
        "The challenge we face today is bridging the gap between the remarkable quality of these neural models and the limited computational resources available on embedded and mobile devices. A modern smartphone can run a high-quality neural TTS model in real time thanks to its multi-core processor, dedicated neural processing unit, and several gigabytes of fast memory. An e-reader like the Kobo, designed primarily for the low-power, low-heat requirements of displaying static text on an e-ink screen, presents a much more constrained environment. Yet it is precisely on such devices that good TTS would be most valuable, transforming a library of ebooks into a library of audiobooks without requiring any additional content purchases or downloads.",
    },
}

--[[--
Get all pages of the test document.
@return table Array of pages, each page is an array of paragraph strings
--]]
function TestDoc:getPages()
    return self.pages
end

--[[--
Get all sentences from all pages, flattened.
Uses simple sentence splitting (period/question/exclamation followed by space or EOL).
@return table Array of {page=N, para=M, sentence_idx=K, text=string}
--]]
function TestDoc:getAllSentences()
    local sentences = {}
    for page_num, page in ipairs(self.pages) do
        for para_num, paragraph in ipairs(page) do
            local sent_idx = 0
            -- Split paragraph into sentences
            local pos = 1
            while pos <= #paragraph do
                local pstart, pend = paragraph:find("[%.%?!\"]+%s", pos)
                if not pstart then
                    pstart, pend = paragraph:find("[%.%?!\"]+$", pos)
                end
                if pstart then
                    local seg_end = pend
                    if paragraph:sub(pend, pend):match("%s") then
                        seg_end = pend - 1
                    end
                    local text = paragraph:sub(pos, seg_end):match("^%s*(.-)%s*$")
                    if text and text ~= "" then
                        sent_idx = sent_idx + 1
                        table.insert(sentences, {
                            page = page_num,
                            para = para_num,
                            sentence_idx = sent_idx,
                            text = text,
                        })
                    end
                    pos = seg_end + 1
                    while pos <= #paragraph and paragraph:sub(pos, pos):match("%s") do
                        pos = pos + 1
                    end
                else
                    local text = paragraph:sub(pos):match("^%s*(.-)%s*$")
                    if text and text ~= "" then
                        sent_idx = sent_idx + 1
                        table.insert(sentences, {
                            page = page_num,
                            para = para_num,
                            sentence_idx = sent_idx,
                            text = text,
                        })
                    end
                    break
                end
            end
        end
    end
    return sentences
end

--[[--
Get all paragraphs from all pages, flattened.
@return table Array of {page=N, para_idx=M, text=string}
--]]
function TestDoc:getAllParagraphs()
    local paragraphs = {}
    for page_num, page in ipairs(self.pages) do
        for para_num, paragraph in ipairs(page) do
            table.insert(paragraphs, {
                page = page_num,
                para_idx = para_num,
                text = paragraph,
            })
        end
    end
    return paragraphs
end

--[[--
Get statistics about the test document.
@return table Stats
--]]
function TestDoc:getStats()
    local sentences = self:getAllSentences()
    local total_chars = 0
    local total_words = 0
    local min_len = math.huge
    local max_len = 0
    local lengths = {}

    for _, s in ipairs(sentences) do
        local len = #s.text
        total_chars = total_chars + len
        min_len = math.min(min_len, len)
        max_len = math.max(max_len, len)
        table.insert(lengths, len)

        for _ in s.text:gmatch("%S+") do
            total_words = total_words + 1
        end
    end

    table.sort(lengths)
    local median_len = lengths[math.ceil(#lengths / 2)] or 0

    return {
        pages = #self.pages,
        paragraphs = #self:getAllParagraphs(),
        sentences = #sentences,
        total_chars = total_chars,
        total_words = total_words,
        min_sentence_len = min_len,
        max_sentence_len = max_len,
        median_sentence_len = median_len,
        avg_sentence_len = total_chars / math.max(1, #sentences),
    }
end

return TestDoc
