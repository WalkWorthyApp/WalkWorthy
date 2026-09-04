/**
 * Reviewed ESV passages available to the mood agent.
 * The model selects only a stable ID; the server supplies the quotation.
 *
 * WHY THIS EXISTS: the model must never write or paraphrase Scripture. A
 * generated quotation can be subtly wrong, which is both a licensing problem
 * and an App Review Guideline 1.1.5 (objectionable/inaccurate religious
 * content) risk. Keeping the text server-side makes every shipped quotation
 * reviewable.
 *
 * VERIFICATION: every entry must match current ESV.org text exactly —
 * wording, punctuation, capitalization, and small-caps LORD rendered as
 * "LORD". The first ten entries were verified September 4, 2026. The
 * remaining entries were added September 4, 2026 and must be re-verified
 * against ESV.org before the next App Store submission.
 *
 * LICENSING: Crossway's gratis-use permission covers quotation up to its
 * published verse limit, provided no complete book is reproduced and the
 * quotations are less than half of the work. Keep additions well inside that
 * allowance and keep the ESV notice in public/terms.html current.
 */
export const SCRIPTURE_CATALOG = {
  // --- Weariness, rest, burnout -------------------------------------------
  matthew_11_28: {
    ref: "Matthew 11:28",
    text: "Come to me, all who labor and are heavy laden, and I will give you rest.",
    themes: "weariness, rest, burdens",
  },
  matthew_11_29_30: {
    ref: "Matthew 11:29-30",
    text: "Take my yoke upon you, and learn from me, for I am gentle and lowly in heart, and you will find rest for your souls. For my yoke is easy, and my burden is light.",
    themes: "exhaustion, gentleness, relief",
  },
  isaiah_40_31: {
    ref: "Isaiah 40:31",
    text: "but they who wait for the LORD shall renew their strength; they shall mount up with wings like eagles; they shall run and not be weary; they shall walk and not faint.",
    themes: "depletion, renewal, endurance",
  },
  isaiah_40_29: {
    ref: "Isaiah 40:29",
    text: "He gives power to the faint, and to him who has no might he increases strength.",
    themes: "burnout, weakness, strength",
  },
  psalm_23_1_3: {
    ref: "Psalm 23:1-3",
    text: "The LORD is my shepherd; I shall not want. He makes me lie down in green pastures. He leads me beside still waters. He restores my soul.",
    themes: "rest, provision, restoration",
  },
  second_corinthians_4_16: {
    ref: "2 Corinthians 4:16",
    text: "So we do not lose heart. Though our outer self is wasting away, our inner self is being renewed day by day.",
    themes: "discouragement, persistence, renewal",
  },
  galatians_6_9: {
    ref: "Galatians 6:9",
    text: "And let us not grow weary of doing good, for in due season we will reap, if we do not give up.",
    themes: "perseverance, work, patience",
  },

  // --- Anxiety, fear, worry ------------------------------------------------
  philippians_4_6_7: {
    ref: "Philippians 4:6-7",
    text: "do not be anxious about anything, but in everything by prayer and supplication with thanksgiving let your requests be made known to God. And the peace of God, which surpasses all understanding, will guard your hearts and your minds in Christ Jesus.",
    themes: "anxiety, prayer, peace",
  },
  first_peter_5_7: {
    ref: "1 Peter 5:7",
    text: "casting all your anxieties on him, because he cares for you.",
    themes: "anxiety, care, trust",
  },
  psalm_55_22: {
    ref: "Psalm 55:22",
    text: "Cast your burden on the LORD, and he will sustain you; he will never permit the righteous to be moved.",
    themes: "worry, burdens, steadiness",
  },
  isaiah_41_10: {
    ref: "Isaiah 41:10",
    text: "fear not, for I am with you; be not dismayed, for I am your God; I will strengthen you, I will help you, I will uphold you with my righteous right hand.",
    themes: "fear, presence, help",
  },
  second_timothy_1_7: {
    ref: "2 Timothy 1:7",
    text: "for God gave us a spirit not of fear but of power and love and self-control.",
    themes: "fear, courage, self-control",
  },
  john_14_27: {
    ref: "John 14:27",
    text: "Peace I leave with you; my peace I give to you. Not as the world gives do I give to you. Let not your hearts be troubled, neither let them be afraid.",
    themes: "unrest, peace, reassurance",
  },
  psalm_56_3: {
    ref: "Psalm 56:3",
    text: "When I am afraid, I put my trust in you.",
    themes: "fear, trust, simplicity",
  },
  psalm_27_1: {
    ref: "Psalm 27:1",
    text: "The LORD is my light and my salvation; whom shall I fear? The LORD is the stronghold of my life; of whom shall I be afraid?",
    themes: "fear, confidence, protection",
  },
  matthew_6_34: {
    ref: "Matthew 6:34",
    text: "Therefore do not be anxious about tomorrow, for tomorrow will be anxious for itself. Sufficient for the day is its own trouble.",
    themes: "future worry, overwhelm, one day at a time",
  },
  deuteronomy_31_6: {
    ref: "Deuteronomy 31:6",
    text: "Be strong and courageous. Do not fear or be in dread of them, for it is the LORD your God who goes with you. He will not leave you or forsake you.",
    themes: "dread, courage, companionship",
  },
  joshua_1_9: {
    ref: "Joshua 1:9",
    text: "Have I not commanded you? Be strong and courageous. Do not be frightened, and do not be dismayed, for the LORD your God is with you wherever you go.",
    themes: "intimidation, courage, presence",
  },

  // --- Grief, loneliness, heartbreak --------------------------------------
  psalm_34_18: {
    ref: "Psalm 34:18",
    text: "The LORD is near to the brokenhearted and saves the crushed in spirit.",
    themes: "grief, loneliness, comfort",
  },
  psalm_147_3: {
    ref: "Psalm 147:3",
    text: "He heals the brokenhearted and binds up their wounds.",
    themes: "hurt, healing, tenderness",
  },
  psalm_23_4: {
    ref: "Psalm 23:4",
    text: "Even though I walk through the valley of the shadow of death, I will fear no evil, for you are with me; your rod and your staff, they comfort me.",
    themes: "darkness, fear, comfort",
  },
  matthew_5_4: {
    ref: "Matthew 5:4",
    text: "Blessed are those who mourn, for they shall be comforted.",
    themes: "mourning, loss, comfort",
  },
  psalm_30_5: {
    ref: "Psalm 30:5",
    text: "For his anger is but for a moment, and his favor is for a lifetime. Weeping may tarry for the night, but joy comes with the morning.",
    themes: "sadness, temporary pain, morning",
  },
  second_corinthians_1_3_4: {
    ref: "2 Corinthians 1:3-4",
    text: "Blessed be the God and Father of our Lord Jesus Christ, the Father of mercies and God of all comfort, who comforts us in all our affliction, so that we may be able to comfort those who are in any affliction, with the comfort with which we ourselves are comforted by God.",
    themes: "affliction, comfort, empathy",
  },
  psalm_42_11: {
    ref: "Psalm 42:11",
    text: "Why are you cast down, O my soul, and why are you in turmoil within me? Hope in God; for I shall again praise him, my salvation and my God.",
    themes: "downcast, turmoil, hope",
  },
  deuteronomy_31_8: {
    ref: "Deuteronomy 31:8",
    text: "It is the LORD who goes before you. He will be with you; he will not leave you or forsake you. Do not fear or be dismayed.",
    themes: "loneliness, abandonment, presence",
  },
  revelation_21_4: {
    ref: "Revelation 21:4",
    text: "He will wipe away every tear from their eyes, and death shall be no more, neither shall there be mourning, nor crying, nor pain anymore, for the former things have passed away.",
    themes: "grief, loss, ultimate hope",
  },

  // --- Hope, joy, gratitude ------------------------------------------------
  romans_15_13: {
    ref: "Romans 15:13",
    text: "May the God of hope fill you with all joy and peace in believing, so that by the power of the Holy Spirit you may abound in hope.",
    themes: "hope, joy, peace",
  },
  psalm_28_7: {
    ref: "Psalm 28:7",
    text: "The LORD is my strength and my shield; in him my heart trusts, and I am helped; my heart exults, and with my song I give thanks to him.",
    themes: "gratitude, confidence, help",
  },
  lamentations_3_22_23: {
    ref: "Lamentations 3:22-23",
    text: "The steadfast love of the LORD never ceases; his mercies never come to an end; they are new every morning; great is your faithfulness.",
    themes: "fresh start, mercy, morning",
  },
  psalm_118_24: {
    ref: "Psalm 118:24",
    text: "This is the day that the LORD has made; let us rejoice and be glad in it.",
    themes: "gladness, present day, celebration",
  },
  first_thessalonians_5_16_18: {
    ref: "1 Thessalonians 5:16-18",
    text: "Rejoice always, pray without ceasing, give thanks in all circumstances; for this is the will of God in Christ Jesus for you.",
    themes: "gratitude, steadiness, prayer",
  },
  psalm_100_4_5: {
    ref: "Psalm 100:4-5",
    text: "Enter his gates with thanksgiving, and his courts with praise! Give thanks to him; bless his name! For the LORD is good; his steadfast love endures forever, and his faithfulness to all generations.",
    themes: "thanksgiving, praise, goodness",
  },
  jeremiah_29_11: {
    ref: "Jeremiah 29:11",
    text: "For I know the plans I have for you, declares the LORD, plans for welfare and not for evil, to give you a future and a hope.",
    themes: "uncertainty, future, hope",
  },
  psalm_16_11: {
    ref: "Psalm 16:11",
    text: "You make known to me the path of life; in your presence there is fullness of joy; at your right hand are pleasures forevermore.",
    themes: "joy, direction, presence",
  },
  psalm_126_5: {
    ref: "Psalm 126:5",
    text: "Those who sow in tears shall reap with shouts of joy!",
    themes: "hard seasons, reward, joy",
  },

  // --- Strength, perseverance, work ---------------------------------------
  psalm_46_1: {
    ref: "Psalm 46:1",
    text: "God is our refuge and strength, a very present help in trouble.",
    themes: "trouble, safety, strength",
  },
  philippians_4_13: {
    ref: "Philippians 4:13",
    text: "I can do all things through him who strengthens me.",
    themes: "capability, strength, challenge",
  },
  colossians_3_23: {
    ref: "Colossians 3:23",
    text: "Whatever you do, work heartily, as for the Lord and not for men,",
    themes: "work, study, motivation",
  },
  first_corinthians_15_58: {
    ref: "1 Corinthians 15:58",
    text: "Therefore, my beloved brothers, be steadfast, immovable, always abounding in the work of the Lord, knowing that in the Lord your labor is not in vain.",
    themes: "effort, meaning, futility",
  },
  psalm_73_26: {
    ref: "Psalm 73:26",
    text: "My flesh and my heart may fail, but God is the strength of my heart and my portion forever.",
    themes: "failure, limits, sustaining",
  },
  romans_5_3_4: {
    ref: "Romans 5:3-4",
    text: "Not only that, but we rejoice in our sufferings, knowing that suffering produces endurance, and endurance produces character, and character produces hope,",
    themes: "hardship, growth, endurance",
  },
  james_1_2_3: {
    ref: "James 1:2-3",
    text: "Count it all joy, my brothers, when you meet trials of various kinds, for you know that the testing of your faith produces steadfastness.",
    themes: "trials, testing, steadfastness",
  },
  hebrews_12_1: {
    ref: "Hebrews 12:1",
    text: "Therefore, since we are surrounded by so great a cloud of witnesses, let us also lay aside every weight, and sin which clings so closely, and let us run with endurance the race that is set before us,",
    themes: "long haul, focus, endurance",
  },

  // --- Wisdom, decisions, direction ---------------------------------------
  james_1_5: {
    ref: "James 1:5",
    text: "If any of you lacks wisdom, let him ask God, who gives generously to all without reproach, and it will be given him.",
    themes: "decisions, wisdom, prayer",
  },
  proverbs_3_5_6: {
    ref: "Proverbs 3:5-6",
    text: "Trust in the LORD with all your heart, and do not lean on your own understanding. In all your ways acknowledge him, and he will make straight your paths.",
    themes: "confusion, trust, direction",
  },
  psalm_119_105: {
    ref: "Psalm 119:105",
    text: "Your word is a lamp to my feet and a light to my path.",
    themes: "guidance, next step, clarity",
  },
  proverbs_16_3: {
    ref: "Proverbs 16:3",
    text: "Commit your work to the LORD, and your plans will be established.",
    themes: "planning, work, surrender",
  },
  psalm_32_8: {
    ref: "Psalm 32:8",
    text: "I will instruct you and teach you in the way you should go; I will counsel you with my eye upon you.",
    themes: "direction, teaching, attention",
  },
  proverbs_16_9: {
    ref: "Proverbs 16:9",
    text: "The heart of man plans his way, but the LORD establishes his steps.",
    themes: "plans changing, control, trust",
  },

  // --- Identity, worth, belonging -----------------------------------------
  psalm_139_14: {
    ref: "Psalm 139:14",
    text: "I praise you, for I am fearfully and wonderfully made. Wonderful are your works; my soul knows it very well.",
    themes: "self-worth, insecurity, identity",
  },
  ephesians_2_10: {
    ref: "Ephesians 2:10",
    text: "For we are his workmanship, created in Christ Jesus for good works, which God prepared beforehand, that we should walk in them.",
    themes: "purpose, calling, worth",
  },
  romans_8_38_39: {
    ref: "Romans 8:38-39",
    text: "For I am sure that neither death nor life, nor angels nor rulers, nor things present nor things to come, nor powers, nor height nor depth, nor anything else in all creation, will be able to separate us from the love of God in Christ Jesus our Lord.",
    themes: "rejection, security, love",
  },
  first_john_3_1: {
    ref: "1 John 3:1",
    text: "See what kind of love the Father has given to us, that we should be called children of God; and so we are.",
    themes: "belonging, love, adoption",
  },
  zephaniah_3_17: {
    ref: "Zephaniah 3:17",
    text: "The LORD your God is in your midst, a mighty one who will save; he will rejoice over you with gladness; he will quiet you by his love; he will exult over you with loud singing.",
    themes: "unloved, delight, quieting",
  },
  psalm_139_23_24: {
    ref: "Psalm 139:23-24",
    text: "Search me, O God, and know my heart! Try me and know my thoughts! And see if there be any grievous way in me, and lead me in the way everlasting!",
    themes: "self-examination, honesty, reflection",
  },

  // --- Guilt, shame, fresh starts -----------------------------------------
  romans_8_1: {
    ref: "Romans 8:1",
    text: "There is therefore now no condemnation for those who are in Christ Jesus.",
    themes: "guilt, condemnation, freedom",
  },
  first_john_1_9: {
    ref: "1 John 1:9",
    text: "If we confess our sins, he is faithful and just to forgive us our sins and to cleanse us from all unrighteousness.",
    themes: "regret, confession, forgiveness",
  },
  psalm_103_12: {
    ref: "Psalm 103:12",
    text: "as far as the east is from the west, so far does he remove our transgressions from us.",
    themes: "shame, distance, forgiveness",
  },
  psalm_51_10: {
    ref: "Psalm 51:10",
    text: "Create in me a clean heart, O God, and renew a right spirit within me.",
    themes: "failure, renewal, clean slate",
  },
  isaiah_43_18_19: {
    ref: "Isaiah 43:18-19",
    text: "Remember not the former things, nor consider the things of old. Behold, I am doing a new thing; now it springs forth, do you not perceive it? I will make a way in the wilderness and rivers in the desert.",
    themes: "the past, new beginnings, change",
  },

  // --- Relationships, community -------------------------------------------
  proverbs_17_17: {
    ref: "Proverbs 17:17",
    text: "A friend loves at all times, and a brother is born for adversity.",
    themes: "friendship, loyalty, hard times",
  },
  ecclesiastes_4_9_10: {
    ref: "Ecclesiastes 4:9-10",
    text: "Two are better than one, because they have a good reward for their toil. For if they fall, one will lift up his fellow. But woe to him who is alone when he falls and has not another to lift him up!",
    themes: "isolation, partnership, support",
  },
  galatians_6_2: {
    ref: "Galatians 6:2",
    text: "Bear one another's burdens, and so fulfill the law of Christ.",
    themes: "carrying others, community, help",
  },
  romans_12_15: {
    ref: "Romans 12:15",
    text: "Rejoice with those who rejoice, weep with those who weep.",
    themes: "empathy, shared joy, shared grief",
  },
  hebrews_10_24_25: {
    ref: "Hebrews 10:24-25",
    text: "And let us consider how to stir up one another to love and good works, not neglecting to meet together, as is the habit of some, but encouraging one another, and all the more as you see the Day drawing near.",
    themes: "withdrawal, gathering, encouragement",
  },
  ephesians_4_32: {
    ref: "Ephesians 4:32",
    text: "Be kind to one another, tenderhearted, forgiving one another, as God in Christ forgave you.",
    themes: "conflict, kindness, forgiveness",
  },

  // --- Stillness, prayer, presence ----------------------------------------
  psalm_46_10: {
    ref: "Psalm 46:10",
    text: "Be still, and know that I am God. I will be exalted among the nations, I will be exalted in the earth!",
    themes: "busyness, stillness, perspective",
  },
  matthew_6_33: {
    ref: "Matthew 6:33",
    text: "But seek first the kingdom of God and his righteousness, and all these things will be added to you.",
    themes: "priorities, focus, provision",
  },
  hebrews_4_16: {
    ref: "Hebrews 4:16",
    text: "Let us then with confidence draw near to the throne of grace, that we may receive mercy and find grace to help in time of need.",
    themes: "need, approach, mercy",
  },
  psalm_145_18: {
    ref: "Psalm 145:18",
    text: "The LORD is near to all who call on him, to all who call on him in truth.",
    themes: "distance from God, nearness, honesty",
  },
  philippians_4_8: {
    ref: "Philippians 4:8",
    text: "Finally, brothers, whatever is true, whatever is honorable, whatever is just, whatever is pure, whatever is lovely, whatever is commendable, if there is any excellence, if there is anything worthy of praise, think about these things.",
    themes: "rumination, thought life, focus",
  },

  // --- Change, transition, uncertainty ------------------------------------
  isaiah_43_2: {
    ref: "Isaiah 43:2",
    text: "When you pass through the waters, I will be with you; and through the rivers, they shall not overwhelm you; when you walk through fire you shall not be burned, and the flame shall not consume you.",
    themes: "overwhelm, danger, accompaniment",
  },
  ecclesiastes_3_1: {
    ref: "Ecclesiastes 3:1",
    text: "For everything there is a season, and a time for every matter under heaven:",
    themes: "seasons, timing, transition",
  },
  psalm_37_5: {
    ref: "Psalm 37:5",
    text: "Commit your way to the LORD; trust in him, and he will act.",
    themes: "waiting, surrender, action",
  },
  romans_8_28: {
    ref: "Romans 8:28",
    text: "And we know that for those who love God all things work together for good, for those who are called according to his purpose.",
    themes: "setbacks, meaning, purpose",
  },
  hebrews_13_8: {
    ref: "Hebrews 13:8",
    text: "Jesus Christ is the same yesterday and today and forever.",
    themes: "instability, constancy, change",
  },
  psalm_121_1_2: {
    ref: "Psalm 121:1-2",
    text: "I lift up my eyes to the hills. From where does my help come? My help comes from the LORD, who made heaven and earth.",
    themes: "looking for help, source, dependence",
  },

  // --- Self-control, anger, temptation ------------------------------------
  first_corinthians_10_13: {
    ref: "1 Corinthians 10:13",
    text: "No temptation has overtaken you that is not common to man. God is faithful, and he will not let you be tempted beyond your ability, but with the temptation he will also provide the way of escape, that you may be able to endure it.",
    themes: "temptation, limits, escape",
  },
  james_1_19: {
    ref: "James 1:19",
    text: "Know this, my beloved brothers: let every person be quick to hear, slow to speak, slow to anger;",
    themes: "anger, listening, restraint",
  },
  proverbs_15_1: {
    ref: "Proverbs 15:1",
    text: "A soft answer turns away wrath, but a harsh word stirs up anger.",
    themes: "conflict, anger, gentleness",
  },
  galatians_5_22_23: {
    ref: "Galatians 5:22-23",
    text: "But the fruit of the Spirit is love, joy, peace, patience, kindness, goodness, faithfulness, gentleness, self-control; against such things there is no law.",
    themes: "character, patience, growth",
  },
} as const;

export type ScriptureId = keyof typeof SCRIPTURE_CATALOG;
export type ScripturePassage = (typeof SCRIPTURE_CATALOG)[ScriptureId];

export const SCRIPTURE_IDS = Object.keys(SCRIPTURE_CATALOG) as [
  ScriptureId,
  ...ScriptureId[],
];

export function resolveScripture(id: string): ScripturePassage | undefined {
  return SCRIPTURE_CATALOG[id as ScriptureId];
}

export const SCRIPTURE_SELECTION_GUIDE = Object.entries(SCRIPTURE_CATALOG)
  .map(([id, passage]) => `${id}: ${passage.ref} (${passage.themes})`)
  .join("\n");
