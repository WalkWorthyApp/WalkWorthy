type Translation = 'ESV' | 'KJV' | 'NIV' | 'NKJV' | 'NASB' | 'CSB' | 'NLT';

interface JsonRpcRequest {
  jsonrpc?: '2.0';
  id?: string | number | null;
  method: string;
  params?: Record<string, unknown>;
}

interface JsonRpcResponse {
  jsonrpc: '2.0';
  id: string | number | null;
  result?: unknown;
  error?: { code: number; message: string };
}

interface Verse {
  ref: string;
  text: string;
  translation: Translation;
  tags?: string[];
}

const VERSE_LIBRARY: Record<string, Partial<Record<Translation, string>>> = {
  'Philippians 4:6-7': {
    ESV: 'Do not be anxious about anything, but in everything by prayer and supplication with thanksgiving let your requests be made known to God. And the peace of God, which surpasses all understanding, will guard your hearts and your minds in Christ Jesus.',
    KJV: 'Be careful for nothing; but in every thing by prayer and supplication with thanksgiving let your requests be made known unto God. And the peace of God, which passeth all understanding, shall keep your hearts and minds through Christ Jesus.'
  },
  '1 Peter 5:7': {
    ESV: 'Casting all your anxieties on him, because he cares for you.',
    KJV: 'Casting all your care upon him; for he careth for you.'
  },
  'John 14:27': {
    ESV: 'Peace I leave with you; my peace I give to you. Not as the world gives do I give to you. Let not your hearts be troubled, neither let them be afraid.',
    KJV: 'Peace I leave with you, my peace I give unto you: not as the world giveth, give I unto you. Let not your heart be troubled, neither let it be afraid.'
  },
  'Matthew 11:28-30': {
    ESV: 'Come to me, all who labor and are heavy laden, and I will give you rest. Take my yoke upon you, and learn from me, for I am gentle and lowly in heart, and you will find rest for your souls. For my yoke is easy, and my burden is light.',
    KJV: 'Come unto me, all ye that labour and are heavy laden, and I will give you rest. Take my yoke upon you, and learn of me; for I am meek and lowly in heart: and ye shall find rest unto your souls. For my yoke is easy, and my burden is light.'
  },
  'Psalm 4:8': {
    ESV: 'In peace I will both lie down and sleep; for you alone, O Lord, make me dwell in safety.',
    KJV: 'I will both lay me down in peace, and sleep: for thou, LORD, only makest me dwell in safety.'
  },
  'James 1:5': {
    ESV: 'If any of you lacks wisdom, let him ask God, who gives generously to all without reproach, and it will be given him.',
    KJV: 'If any of you lack wisdom, let him ask of God, that giveth to all men liberally, and upbraideth not; and it shall be given him.'
  },
  'Isaiah 41:10': {
    ESV: 'Fear not, for I am with you; be not dismayed, for I am your God; I will strengthen you, I will help you, I will uphold you with my righteous right hand.',
    KJV: 'Fear thou not; for I am with thee: be not dismayed; for I am thy God: I will strengthen thee; yea, I will help thee; yea, I will uphold thee with the right hand of my righteousness.'
  },
  'Romans 8:38-39': {
    ESV: 'For I am sure that neither death nor life, nor angels nor rulers, nor things present nor things to come, nor powers, nor height nor depth, nor anything else in all creation, will be able to separate us from the love of God in Christ Jesus our Lord.',
    KJV: 'For I am persuaded, that neither death, nor life, nor angels, nor principalities, nor powers, nor things present, nor things to come, Nor height, nor depth, nor any other creature, shall be able to separate us from the love of God, which is in Christ Jesus our Lord.'
  },
  'Psalm 23:4': {
    ESV: 'Even though I walk through the valley of the shadow of death, I will fear no evil, for you are with me; your rod and your staff, they comfort me.',
    KJV: 'Yea, though I walk through the valley of the shadow of death, I will fear no evil: for thou art with me; thy rod and thy staff they comfort me.'
  },
  'Joshua 1:9': {
    ESV: 'Have I not commanded you? Be strong and courageous. Do not be frightened, and do not be dismayed, for the Lord your God is with you wherever you go.',
    KJV: 'Have not I commanded thee? Be strong and of a good courage; be not afraid, neither be thou dismayed: for the LORD thy God is with thee whithersoever thou goest.'
  },
  'Psalm 46:1-2': {
    ESV: 'God is our refuge and strength, a very present help in trouble. Therefore we will not fear though the earth gives way, though the mountains be moved into the heart of the sea.',
    KJV: 'God is our refuge and strength, a very present help in trouble. Therefore will not we fear, though the earth be removed, and though the mountains be carried into the midst of the sea.'
  }
};

const KEYWORD_MAP: Record<string, string[]> = {
  anxiety: ['Philippians 4:6-7', '1 Peter 5:7', 'John 14:27'],
  stress: ['Philippians 4:6-7', 'Matthew 11:28-30', 'Psalm 4:8'],
  rest: ['Matthew 11:28-30', 'Psalm 4:8'],
  peace: ['John 14:27', 'Philippians 4:6-7'],
  wisdom: ['James 1:5'],
  courage: ['Joshua 1:9', 'Psalm 23:4'],
  strength: ['Isaiah 41:10', 'Psalm 46:1-2'],
  hope: ['Romans 8:38-39', 'Psalm 23:4'],
  exam: ['James 1:5', 'Philippians 4:6-7'],
  deadline: ['Philippians 4:6-7', 'Matthew 11:28-30'],
  urgency: ['Isaiah 41:10', 'Matthew 11:28-30'],
  overdue: ['Psalm 4:8', 'John 14:27'],
  encouragement: ['John 14:27', 'Romans 8:38-39'],
  community: ['Romans 8:38-39', 'Psalm 23:4']
};

const DEFAULT_TRANSLATION: Translation = 'ESV';

export async function handler(event: JsonRpcRequest | { body?: string }) {
  const request = normalizeRequest(event);
  if (!request) {
    return buildResponse(null, undefined, {
      code: -32600,
      message: 'Invalid request',
    });
  }

  try {
    let result: unknown;
    switch (request.method) {
      case 'search_verses':
        result = handleSearch(request.params ?? {});
        break;
      case 'get_verse_by_reference':
        result = handleGetByReference(request.params ?? {});
        break;
      default:
        return buildResponse(request.id ?? null, undefined, {
          code: -32601,
          message: `Unknown method ${request.method}`,
        });
    }
    return buildResponse(request.id ?? null, result);
  } catch (err) {
    console.error('Bible MCP bridge error', err);
    return buildResponse(request.id ?? null, undefined, {
      code: -32000,
      message: err instanceof Error ? err.message : 'Internal error',
    });
  }
}

function normalizeRequest(event: JsonRpcRequest | { body?: string }): JsonRpcRequest | undefined {
  if (!event) return undefined;
  if ('body' in event && typeof event.body === 'string') {
    try {
      return JSON.parse(event.body) as JsonRpcRequest;
    } catch {
      return undefined;
    }
  }
  if (typeof event === 'object') {
    return event as JsonRpcRequest;
  }
  return undefined;
}

function handleSearch(params: Record<string, unknown>): Verse[] {
  const keywordsRaw = params.keywords;
  const translation = normalizeTranslation(params.translation);
  const limit = Math.max(1, Math.min(5, Number(params.limit) || 5));

  if (!Array.isArray(keywordsRaw) || keywordsRaw.length === 0) {
    throw new Error('keywords must be a non-empty array');
  }

  const refs: string[] = [];
  for (const keywordRaw of keywordsRaw) {
    const keyword = String(keywordRaw).toLowerCase().trim();
    if (!keyword) continue;
    const mapped = KEYWORD_MAP[keyword] ?? [];
    for (const ref of mapped) {
      if (!refs.includes(ref)) refs.push(ref);
      if (refs.length >= limit) break;
    }
    if (refs.length >= limit) break;
  }

  if (refs.length === 0) {
    refs.push('Philippians 4:6-7');
  }

  const verses: Verse[] = refs.slice(0, limit).map((ref) => buildVerse(ref, translation));
  return verses;
}

function handleGetByReference(params: Record<string, unknown>): Verse | null {
  const ref = typeof params.ref === 'string' ? params.ref : undefined;
  if (!ref) throw new Error('ref is required');
  const translation = normalizeTranslation(params.translation);
  return buildVerse(ref, translation, true);
}

function buildVerse(ref: string, translation: Translation, allowNull = false): Verse {
  const record = VERSE_LIBRARY[ref];
  if (!record) {
    if (allowNull) {
      return {
        ref,
        text: 'Verse not found in bridge dataset. Please expand the MCP bridge library.',
        translation,
      };
    }
    throw new Error(`Reference ${ref} not found in bridge dataset`);
  }

  const text =
    record[translation] ??
    record[DEFAULT_TRANSLATION] ??
    'Verse not found in bridge dataset. Please expand the MCP bridge library.';
  return {
    ref,
    text,
    translation,
  };
}

function normalizeTranslation(value: unknown): Translation {
  const upper = typeof value === 'string' ? value.toUpperCase() : DEFAULT_TRANSLATION;
  const allowed: Translation[] = ['ESV', 'KJV', 'NIV', 'NKJV', 'NASB', 'CSB', 'NLT'];
  return allowed.includes(upper as Translation) ? (upper as Translation) : DEFAULT_TRANSLATION;
}

function buildResponse(id: string | number | null, result?: unknown, error?: { code: number; message: string }): JsonRpcResponse {
  const response: JsonRpcResponse = {
    jsonrpc: '2.0',
    id,
  };
  if (error) {
    response.error = error;
  } else {
    response.result = result;
  }
  return response;
}
