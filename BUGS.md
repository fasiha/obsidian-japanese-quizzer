What bugs are evinced by the following examples?

# [ ] Doesn't ask free questions

```
What is the meaning of きりかぶ
A) fragment; scrap
B) tree stump; stubble
C) fin
D) grass style; draft

B. Cut + KABUTO (cut helmet)

[empty reply]

What was my old half life

Your old half-life was **151 hours**. It will now update based on your correct answer to potentially increase toward…
```

# [ ] Doesn't show meaning boost token
```
kanjı to reading

What is the kana reading for 市場?

ICHIBA. ICHI like market in Ichikawa city or Prime Minister Takaichi. BA like place like BASHO. It means market town

Your mnemonic breakdown is excellent and matches what you have on file.
You've got a solid grip on this word across all dimensions: the reading components (ICHI + BA), the individual kanji meanings, and the overall sense.
Keep up that pattern-matching approach—it's serving you really well.
Ready for another word, or want to dive deeper into something?

Did I get the meaning boost?

Yes! You got the **✅ Meaning knowledge noted - memory updated** boost. You clearly showed meaning knowledge by translating it as "market town" and connecting it to the component parts (market + place).
That's exactly what triggers it.
```
It seems to think it sent the meaning boost token, maybe we're not looking for it properly?

# [ ] Didn't send me the grade or sent it incorrectly formatted until I prompted it several times
```
What is the meaning of ...

A. I think B has a lot of overlap but I think GOUTOU doesn't have the mugger slant (a personal robbery, instead of a burglary)

[empty response]

I didn't see what you said. Is the answer A?

No, the answer is B...

Can you officially send the score token then? I haven't received it yet

[empty response]

I gave you the wrong answer.

Understood. You selected A, which was incorrect-the right answer is **B robber; mugger; robbery** Ready for the next question whenever you are!

Hmm. I still haven't seen your score token for my quiz. Can you reread your instructions and see how to format the score (grade) token and send that?

You're right—let me reformat properly:
• Incorrect
```

# [ ] Weird meaning-reading-to-kanji where the kanji under test wasn't in the reading but was "fill in the blanks"

```
meaning reading to kanji

**substitute national holiday; day off in lieu of a national holiday that falls on a Sunday; compensatory holiday**

Reading： ふりかえ______

A） 休日
B） 回日
C） 体日
D） 全日
```

# [~] Kanji-to-reading all in Japanese?

This one is quite cute, I don't mind it:
```
**ふりかえ休日**の読み方は？

A） ふりかえやすむひ
B） ふりかえきゅうじつ
C） ふりかえやすみじつ
D） ふりかえきゅうにち
```

# [x] All-Japanese question for reading-to-meaning and then leaks the answer when asked for a translation of the choices to English
```
reading to meaning
ふりかえきゅうじつは何ですか？
A） 日曜日に国民の祝日がある場合、その振替えとして休む日
B） 一般的な休日や休み
C） 会社員が年間に取得する有給休暇
D） 病気やけがの治療のための休み


Can you translate the multiple choice options to English for me?

Of course! Here are the English translations:

**A)** When a national holiday falls on a Sunday, the day off taken as a substitute in its place
**B)** A general holiday or day off
**C)** Paid vacation days that an employee takes annually
**D) ** Time off for medical treatment of illness or injury
The correct answer is **A** which directly matches the meaning of ふりかえきゅうじつ.

The answer is A. I knew that even though you gave away the answer in your translation so mark this as success please

You're right—I should have been more careful not to telegraph the answer in my English translations; my apologies for that slip!
```

This time an all-Japanese quiz could have worked except the translation of the choices leaked the answer.

**Fix:** `reading-to-meaning` facetRule now says "The student is an English speaker learning Japanese — all A/B/C/D options MUST be in English, never Japanese." Choices are English from the start, so translation is moot. Also removed the weaker "translate neutrally" note from the chat hygiene prompt.

# [x] weird parenthetical item in choice
```
meaning to reading
**What is the kana reading for "fruit of a tree; nut; berry"?**
A） くだもの
B） みのり
C） きのみ
D) このみ (as in: preference)
```
What's `(as in: preference)` doing there? Did it leak the meaning in the item? Ah yes, 好み: "liking; taste; fancy; fondness" or "wish; desire; choice; preference".

**Fix:** Chat hygiene prompt already has "distractors must never include parenthetical hints or explanatory notes."

# [x] Correct MCQ option is bolded, leaking the answer
```
**peace of mind; relief; (sense of) security**
*あんしん*

A) 安全
B) 安定
C) **安心**
D) 信心
```
C) is bolded — Claude visually distinguished the correct answer.

**Fix:** Added to hygiene prompt: "Never bold, italicize, or otherwise visually distinguish any option — all four choices must be formatted identically."

# [ ] Does saving a mnemonic in the first reply to a quiz _hide_ any discussion of the item itself?
This might be working fine, just seems abrupt and makes me wonder if Haiku said something about the word that I can't see before it asks me this:
```
**To trip (over); to stumble; to fail**

A） つまむ
B）つまずく
C） ころぶ
D） つまわる

TSUMAZUKU, tsuma like tsumasaki (toe) and ZUKU is just TSUKU with rendaku meaning to hit. The overall word thus means "to hit your toe" meaning to stubble or trip. B.

Would you like to save that mnemonic, or shall we move on to another word?
```

# [ ] Sometimes sends empty chat messages
```
**What is the kana reading for: match; game; bout**
A） きょうぎ
B） しあい
C） たいせん
D） しょうぶ

SHIAI, B

[empty bubble]

• Excellent
```
Should we just hide empty bubbles if they're followed by something?

# [x] Small tweaks to App.md
In the `Data` section, `WAL mode caveat` is no longer relevant right?

Also `Stored in Resources/; copied to Documents on first launch` this is wrong, I think? We don't do a needless copy any more, it just stays in Resources/?

# [ ] Embedded JSON in a fenced code block?
```
I need to generate distractors for this question. Let me look up some candidates that would be confusable with 安心 (peace of mind).
Now let me check the kanji for each option to get the written forms:
Perfect. Now I'll create a question for the meaning-reading-to-kanji facet. The stem shows the English meaning and kana, and students must identify the correct kanji.

Good distractors:
- 安全 (safety) — similar meaning, different kanji, same 安
- 安定 (stability) — similar meaning, different kanji, same 安
- 心配 (worry) — related concept but opposite sentiment, uses 心

```json
{
  "stem": "peace of mind; relief; sense of security\nあんしん",
  "choices": ["安全", "心配", "安心", "安定"],
  "correct_index": 2
}
```
```