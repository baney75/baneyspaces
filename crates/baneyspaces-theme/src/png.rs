//! A small PNG writer: 8-bit RGB, one IDAT, deflate with the fixed Huffman codes and a greedy
//! LZ77 match search. Theme previews are flat colors, so that compresses them well, and it keeps
//! the command free of image libraries.

/// The text chunk every preview image carries right after IHDR. A file without it is not ours,
/// and `preview --out` will not replace it.
const MARK_KEY: &[u8] = b"polycarp\0theme-preview";

/// Where the mark chunk starts: the 8-byte signature plus the 25-byte IHDR chunk.
const MARK_AT: usize = 33;

fn crc_table() -> [u32; 256] {
    let mut t = [0u32; 256];
    for (n, slot) in t.iter_mut().enumerate() {
        let mut c = n as u32;
        for _ in 0..8 {
            c = if c & 1 != 0 {
                0xEDB8_8320 ^ (c >> 1)
            } else {
                c >> 1
            };
        }
        *slot = c;
    }
    t
}

pub(super) fn crc32(parts: &[&[u8]]) -> u32 {
    let t = crc_table();
    let mut c = 0xFFFF_FFFFu32;
    for p in parts {
        for b in *p {
            c = t[((c ^ *b as u32) & 0xFF) as usize] ^ (c >> 8);
        }
    }
    c ^ 0xFFFF_FFFF
}

fn adler32(data: &[u8]) -> u32 {
    let (mut a, mut b) = (1u32, 0u32);
    for chunk in data.chunks(5552) {
        for x in chunk {
            a += *x as u32;
            b += a;
        }
        a %= 65521;
        b %= 65521;
    }
    (b << 16) | a
}

fn chunk(out: &mut Vec<u8>, kind: &[u8; 4], data: &[u8]) {
    out.extend_from_slice(&(data.len() as u32).to_be_bytes());
    out.extend_from_slice(kind);
    out.extend_from_slice(data);
    out.extend_from_slice(&crc32(&[kind, data]).to_be_bytes());
}

/// True when `head` (the first bytes of a file) is a preview image this command wrote.
pub(super) fn is_ours(head: &[u8]) -> bool {
    let want = MARK_KEY.len();
    head.len() >= MARK_AT + 8 + want
        && head[..8] == SIGNATURE
        && head[MARK_AT..MARK_AT + 4] == (want as u32).to_be_bytes()
        && &head[MARK_AT + 4..MARK_AT + 8] == b"tEXt"
        && &head[MARK_AT + 8..MARK_AT + 8 + want] == MARK_KEY
}

/// How many bytes `is_ours` needs to see.
pub(super) const HEAD_LEN: usize = MARK_AT + 8 + MARK_KEY.len();

const SIGNATURE: [u8; 8] = [0x89, b'P', b'N', b'G', b'\r', b'\n', 0x1A, b'\n'];

/// `rgb` is `w * h * 3` bytes, rows top to bottom.
pub(super) fn encode(w: u32, h: u32, rgb: &[u8]) -> Vec<u8> {
    assert_eq!(rgb.len(), w as usize * h as usize * 3, "pixel buffer size");
    let mut out = SIGNATURE.to_vec();
    let mut ihdr = Vec::with_capacity(13);
    ihdr.extend_from_slice(&w.to_be_bytes());
    ihdr.extend_from_slice(&h.to_be_bytes());
    ihdr.extend_from_slice(&[8, 2, 0, 0, 0]);
    chunk(&mut out, b"IHDR", &ihdr);
    chunk(&mut out, b"tEXt", MARK_KEY);
    let raw = filter(w as usize, h as usize, rgb);
    let mut z = vec![0x78, 0x01];
    z.extend_from_slice(&deflate(&raw));
    z.extend_from_slice(&adler32(&raw).to_be_bytes());
    chunk(&mut out, b"IDAT", &z);
    chunk(&mut out, b"IEND", &[]);
    out
}

/// Each row gets the filter (none, sub or up) with the smallest sum of bytes, the usual guess.
fn filter(w: usize, h: usize, rgb: &[u8]) -> Vec<u8> {
    let stride = w * 3;
    let mut out = Vec::with_capacity(h * (stride + 1));
    let mut cand = vec![0u8; stride];
    let mut best = vec![0u8; stride];
    for y in 0..h {
        let row = &rgb[y * stride..(y + 1) * stride];
        let up = (y > 0).then(|| &rgb[(y - 1) * stride..y * stride]);
        let mut best_kind = 0u8;
        let mut best_cost = u64::MAX;
        for kind in 0u8..3 {
            if kind == 2 && up.is_none() {
                continue;
            }
            for i in 0..stride {
                let pred = match kind {
                    1 if i >= 3 => row[i - 3],
                    2 => up.map_or(0, |u| u[i]),
                    _ => 0,
                };
                cand[i] = row[i].wrapping_sub(pred);
            }
            let cost: u64 = cand.iter().map(|b| (*b as i8).unsigned_abs() as u64).sum();
            if cost < best_cost {
                best_cost = cost;
                best_kind = kind;
                best.copy_from_slice(&cand);
            }
        }
        out.push(best_kind);
        out.extend_from_slice(&best);
    }
    out
}

const LBASE: [u32; 29] = [
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131,
    163, 195, 227, 258,
];
const LEXTRA: [u32; 29] = [
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
];
const DBASE: [u32; 30] = [
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537,
    2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
];
const DEXTRA: [u32; 30] = [
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13,
    13,
];

struct Bits {
    out: Vec<u8>,
    acc: u64,
    n: u32,
}

impl Bits {
    fn put(&mut self, v: u32, len: u32) {
        self.acc |= (v as u64) << self.n;
        self.n += len;
        while self.n >= 8 {
            self.out.push(self.acc as u8);
            self.acc >>= 8;
            self.n -= 8;
        }
    }
    /// A Huffman code goes in most significant bit first.
    fn code(&mut self, code: u32, len: u32) {
        let mut r = 0;
        for i in 0..len {
            r |= ((code >> i) & 1) << (len - 1 - i);
        }
        self.put(r, len);
    }
    fn sym(&mut self, s: u32) {
        match s {
            0..=143 => self.code(0x30 + s, 8),
            144..=255 => self.code(0x190 + s - 144, 9),
            256..=279 => self.code(s - 256, 7),
            _ => self.code(0xC0 + s - 280, 8),
        }
    }
    fn length(&mut self, len: u32) {
        let i = LBASE.iter().rposition(|b| *b <= len).unwrap_or(0);
        self.sym(257 + i as u32);
        self.put(len - LBASE[i], LEXTRA[i]);
    }
    fn distance(&mut self, d: u32) {
        let i = DBASE.iter().rposition(|b| *b <= d).unwrap_or(0);
        self.code(i as u32, 5);
        self.put(d - DBASE[i], DEXTRA[i]);
    }
}

const WINDOW: usize = 32 * 1024;
const MAX_MATCH: usize = 258;
const CHAIN: usize = 48;

fn deflate(data: &[u8]) -> Vec<u8> {
    let mut b = Bits {
        out: Vec::new(),
        acc: 0,
        n: 0,
    };
    // One final block with the fixed codes.
    b.put(1, 1);
    b.put(1, 2);
    let n = data.len();
    const HBITS: usize = 15;
    let mut head = vec![usize::MAX; 1 << HBITS];
    let mut prev = vec![usize::MAX; n];
    let hash = |i: usize| -> usize {
        let v = (data[i] as u32) << 16 | (data[i + 1] as u32) << 8 | data[i + 2] as u32;
        (v.wrapping_mul(2_654_435_761) >> (32 - HBITS)) as usize
    };
    let insert = |i: usize, head: &mut [usize], prev: &mut [usize]| {
        if i + 3 <= n {
            let h = hash(i);
            prev[i] = head[h];
            head[h] = i;
        }
    };
    let mut i = 0;
    while i < n {
        let mut best_len = 0;
        let mut best_dist = 0;
        if i + 3 <= n {
            let mut cand = head[hash(i)];
            let limit = (n - i).min(MAX_MATCH);
            let mut tries = 0;
            while cand != usize::MAX && i - cand <= WINDOW && tries < CHAIN {
                let mut l = 0;
                while l < limit && data[cand + l] == data[i + l] {
                    l += 1;
                }
                if l > best_len {
                    best_len = l;
                    best_dist = i - cand;
                    if l == limit {
                        break;
                    }
                }
                cand = prev[cand];
                tries += 1;
            }
        }
        if best_len >= 3 {
            b.length(best_len as u32);
            b.distance(best_dist as u32);
            for k in i..i + best_len {
                insert(k, &mut head, &mut prev);
            }
            i += best_len;
        } else {
            b.sym(data[i] as u32);
            insert(i, &mut head, &mut prev);
            i += 1;
        }
    }
    b.sym(256);
    if b.n > 0 {
        b.out.push(b.acc as u8);
    }
    b.out
}

#[cfg(test)]
pub(super) mod tests {
    use super::*;

    /// Inflates what `deflate` writes: one final block with the fixed codes.
    fn inflate_fixed(src: &[u8]) -> Vec<u8> {
        let mut pos = 0usize;
        let mut bit = |count: u32| -> u32 {
            let mut v = 0;
            for k in 0..count {
                let byte = src[pos / 8];
                v |= (((byte >> (pos % 8)) & 1) as u32) << k;
                pos += 1;
            }
            v
        };
        assert_eq!(bit(1), 1, "final block");
        assert_eq!(bit(2), 1, "fixed codes");
        let mut out: Vec<u8> = Vec::new();
        loop {
            // Read a code most significant bit first.
            let mut code = 0u32;
            for _ in 0..7 {
                code = (code << 1) | bit(1);
            }
            let sym = if code <= 23 {
                256 + code
            } else {
                code = (code << 1) | bit(1);
                if (0x30..=0xBF).contains(&code) {
                    code - 0x30
                } else if (0xC0..=0xC7).contains(&code) {
                    280 + code - 0xC0
                } else {
                    code = (code << 1) | bit(1);
                    144 + code - 0x190
                }
            };
            match sym {
                0..=255 => out.push(sym as u8),
                256 => return out,
                _ => {
                    let i = (sym - 257) as usize;
                    let len = LBASE[i] + bit(LEXTRA[i]);
                    let mut dc = 0u32;
                    for _ in 0..5 {
                        dc = (dc << 1) | bit(1);
                    }
                    let d = (DBASE[dc as usize] + bit(DEXTRA[dc as usize])) as usize;
                    for _ in 0..len {
                        let b = out[out.len() - d];
                        out.push(b);
                    }
                }
            }
        }
    }

    /// Reads back a PNG this module wrote: (width, height, rgb), checking every CRC.
    pub(crate) fn decode(png: &[u8]) -> (u32, u32, Vec<u8>) {
        assert_eq!(png[..8], SIGNATURE);
        let mut at = 8;
        let (mut w, mut h, mut z) = (0u32, 0u32, Vec::new());
        while at < png.len() {
            let len = u32::from_be_bytes(png[at..at + 4].try_into().unwrap()) as usize;
            let kind = &png[at + 4..at + 8];
            let data = &png[at + 8..at + 8 + len];
            let crc = u32::from_be_bytes(png[at + 8 + len..at + 12 + len].try_into().unwrap());
            assert_eq!(crc, crc32(&[kind, data]), "crc of {:?}", kind);
            match kind {
                b"IHDR" => {
                    w = u32::from_be_bytes(data[0..4].try_into().unwrap());
                    h = u32::from_be_bytes(data[4..8].try_into().unwrap());
                    assert_eq!(&data[8..], &[8, 2, 0, 0, 0]);
                }
                b"IDAT" => z.extend_from_slice(data),
                _ => {}
            }
            at += 12 + len;
        }
        assert_eq!((z[0], z[1]), (0x78, 0x01));
        let raw = inflate_fixed(&z[2..z.len() - 4]);
        assert_eq!(
            u32::from_be_bytes(z[z.len() - 4..].try_into().unwrap()),
            adler32(&raw)
        );
        let stride = w as usize * 3;
        let mut rgb = vec![0u8; stride * h as usize];
        for y in 0..h as usize {
            let line = &raw[y * (stride + 1)..(y + 1) * (stride + 1)];
            for i in 0..stride {
                let pred = match line[0] {
                    0 => 0,
                    1 if i >= 3 => rgb[y * stride + i - 3],
                    1 => 0,
                    2 if y > 0 => rgb[(y - 1) * stride + i],
                    2 => 0,
                    f => panic!("filter {f}"),
                };
                rgb[y * stride + i] = line[1 + i].wrapping_add(pred);
            }
        }
        (w, h, rgb)
    }

    #[test]
    fn the_empty_chunk_crc_is_the_known_one() {
        assert_eq!(crc32(&[b"IEND"]), 0xAE42_6082);
        assert_eq!(adler32(b"Wikipedia"), 0x11E6_0398);
    }

    #[test]
    fn an_image_comes_back_pixel_for_pixel_and_small() {
        let (w, h) = (97u32, 61u32);
        let mut rgb = Vec::new();
        for y in 0..h {
            for x in 0..w {
                // Flat bands with an edge and some noise, like a preview with text.
                let band = if x < 40 { 200 } else { 30 };
                let noise = ((x * 7 + y * 13) % 5) as u8;
                rgb.extend_from_slice(&[band, (y * 3) as u8, band.wrapping_add(noise)]);
            }
        }
        let png = encode(w, h, &rgb);
        assert!(is_ours(&png[..HEAD_LEN]));
        let (dw, dh, back) = decode(&png);
        assert_eq!((dw, dh), (w, h));
        assert!(back == rgb, "pixels differ after a round trip");
        let flat = vec![240u8; 400 * 300 * 3];
        let small = encode(400, 300, &flat);
        assert!(small.len() < 6000, "a flat image is {} bytes", small.len());
        assert_eq!(decode(&small).2, flat);
    }

    #[test]
    fn a_png_from_elsewhere_is_not_ours() {
        let mut other = SIGNATURE.to_vec();
        other.extend_from_slice(&[0u8; 64]);
        assert!(!is_ours(&other));
        assert!(!is_ours(b"<!-- polycarp-theme-preview -->"));
    }
}
