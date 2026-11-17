//! A PNG writer for `agent shot`: 8-bit RGB, one IDAT holding a zlib stream compressed with
//! deflate's fixed Huffman codes (RFC 1951 3.2.6) and greedy LZ77 matches. Here so the shot can
//! compare grim's raw frames and encode only the one it keeps, with no new dependency.
//!
//! Every row uses filter 0 (none). A window is mostly flat colour and repeated rows, which the
//! matches at one pixel back and one row up find; the rest gets a hash of the next three bytes.

const WINDOW: usize = 32 * 1024;
const MIN_MATCH: usize = 3;
const MAX_MATCH: usize = 258;
const HASH_BITS: u32 = 15;

/// The PNG of a `width` by `height` picture whose pixels are `rgb`, three bytes each, row by row.
/// None when the sizes disagree.
pub fn encode_rgb(width: u32, height: u32, rgb: &[u8]) -> Option<Vec<u8>> {
    let stride = (width as usize).checked_mul(3)?;
    if width == 0 || height == 0 || stride.checked_mul(height as usize)? != rgb.len() {
        return None;
    }
    let mut raw = Vec::with_capacity(rgb.len() + height as usize);
    for row in rgb.chunks_exact(stride) {
        raw.push(0);
        raw.extend_from_slice(row);
    }
    let mut z = vec![0x78, 0x01];
    deflate_fixed(&raw, stride + 1, &mut z);
    z.extend_from_slice(&adler32(&raw).to_be_bytes());

    let mut ihdr = Vec::with_capacity(13);
    ihdr.extend_from_slice(&width.to_be_bytes());
    ihdr.extend_from_slice(&height.to_be_bytes());
    ihdr.extend_from_slice(&[8, 2, 0, 0, 0]); // 8 bits, RGB, deflate, filter set 0, no interlace
    let mut out = b"\x89PNG\r\n\x1a\n".to_vec();
    chunk(&mut out, b"IHDR", &ihdr);
    chunk(&mut out, b"IDAT", &z);
    chunk(&mut out, b"IEND", &[]);
    Some(out)
}

fn chunk(out: &mut Vec<u8>, kind: &[u8; 4], data: &[u8]) {
    out.extend_from_slice(&(data.len() as u32).to_be_bytes());
    let start = out.len();
    out.extend_from_slice(kind);
    out.extend_from_slice(data);
    let crc = crc32(&out[start..]);
    out.extend_from_slice(&crc.to_be_bytes());
}

const CRC_TABLE: [u32; 256] = {
    let mut t = [0u32; 256];
    let mut n = 0;
    while n < 256 {
        let mut c = n as u32;
        let mut k = 0;
        while k < 8 {
            c = if c & 1 == 1 {
                0xedb8_8320 ^ (c >> 1)
            } else {
                c >> 1
            };
            k += 1;
        }
        t[n] = c;
        n += 1;
    }
    t
};

/// CRC-32 as PNG uses it (ISO 3309).
pub fn crc32(data: &[u8]) -> u32 {
    !data.iter().fold(!0u32, |c, &b| {
        CRC_TABLE[((c ^ b as u32) & 0xff) as usize] ^ (c >> 8)
    })
}

/// Adler-32 as zlib uses it (RFC 1950).
pub fn adler32(data: &[u8]) -> u32 {
    let (mut a, mut b) = (1u32, 0u32);
    for block in data.chunks(5552) {
        for &x in block {
            a += x as u32;
            b += a;
        }
        a %= 65521;
        b %= 65521;
    }
    (b << 16) | a
}

struct Bits<'a> {
    out: &'a mut Vec<u8>,
    acc: u64,
    n: u32,
}

impl Bits<'_> {
    /// Appends the low `n` bits of `v`, first bit first (deflate's order for everything but codes).
    fn put(&mut self, v: u32, n: u32) {
        self.acc |= (v as u64) << self.n;
        self.n += n;
        while self.n >= 8 {
            self.out.push(self.acc as u8);
            self.acc >>= 8;
            self.n -= 8;
        }
    }

    /// A Huffman code goes most significant bit first.
    fn code(&mut self, code: u32, len: u32) {
        self.put(code.reverse_bits() >> (32 - len), len);
    }

    fn literal(&mut self, sym: u32) {
        match sym {
            0..=143 => self.code(0x30 + sym, 8),
            144..=255 => self.code(0x190 + sym - 144, 9),
            256..=279 => self.code(sym - 256, 7),
            _ => self.code(0xc0 + sym - 280, 8),
        }
    }

    fn finish(mut self) {
        if self.n > 0 {
            self.out.push(self.acc as u8);
        }
        self.n = 0;
    }
}

const LEN_BASE: [u16; 29] = [
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131,
    163, 195, 227, 258,
];
const LEN_EXTRA: [u8; 29] = [
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
];
const DIST_BASE: [u16; 30] = [
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537,
    2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
];
const DIST_EXTRA: [u8; 30] = [
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13,
    13,
];

/// The last table entry whose base is at most `v`.
fn slot(bases: &[u16], v: usize) -> usize {
    bases.partition_point(|&b| b as usize <= v) - 1
}

fn hash3(d: &[u8]) -> usize {
    let v = d[0] as u32 | (d[1] as u32) << 8 | (d[2] as u32) << 16;
    (v.wrapping_mul(0x9e37_79b1) >> (32 - HASH_BITS)) as usize
}

fn match_len(data: &[u8], from: usize, at: usize) -> usize {
    let max = MAX_MATCH.min(data.len() - at);
    data[from..from + max]
        .iter()
        .zip(&data[at..at + max])
        .take_while(|(a, b)| a == b)
        .count()
}

/// One final deflate block with the fixed codes. `row` is the distance one row up in `data`.
fn deflate_fixed(data: &[u8], row: usize, out: &mut Vec<u8>) {
    let mut bits = Bits { out, acc: 0, n: 0 };
    bits.put(1, 1); // the last block
    bits.put(1, 2); // fixed Huffman codes
    let mut head = vec![usize::MAX; 1 << HASH_BITS];
    let mut i = 0;
    while i < data.len() {
        let (mut len, mut dist) = (0, 0);
        if i + MIN_MATCH <= data.len() {
            let h = hash3(&data[i..]);
            let seen = head[h];
            head[h] = i;
            for from in [i.wrapping_sub(3), i.wrapping_sub(row), seen] {
                if from < i && i - from <= WINDOW {
                    let l = match_len(data, from, i);
                    if l > len {
                        (len, dist) = (l, i - from);
                    }
                }
            }
        }
        if len < MIN_MATCH {
            bits.literal(data[i] as u32);
            i += 1;
            continue;
        }
        let s = slot(&LEN_BASE, len);
        bits.literal(257 + s as u32);
        bits.put((len - LEN_BASE[s] as usize) as u32, LEN_EXTRA[s] as u32);
        let s = slot(&DIST_BASE, dist);
        bits.code(s as u32, 5);
        bits.put((dist - DIST_BASE[s] as usize) as u32, DIST_EXTRA[s] as u32);
        i += len;
    }
    bits.literal(256);
    bits.finish();
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Reads back what `encode_rgb` writes: the chunks, their CRCs, the zlib wrapper and a deflate
    /// stream of fixed-code blocks. Returns (width, height, colour type, pixels).
    fn decode(png: &[u8]) -> (u32, u32, u8, Vec<u8>) {
        assert_eq!(&png[..8], b"\x89PNG\r\n\x1a\n");
        let (mut p, mut ihdr, mut idat) = (8, vec![], vec![]);
        loop {
            let n = u32::from_be_bytes(png[p..p + 4].try_into().unwrap()) as usize;
            let kind = &png[p + 4..p + 8];
            let body = &png[p + 8..p + 8 + n];
            let crc = u32::from_be_bytes(png[p + 8 + n..p + 12 + n].try_into().unwrap());
            assert_eq!(
                crc,
                crc32(&png[p + 4..p + 8 + n]),
                "the CRC of {:?}",
                std::str::from_utf8(kind)
            );
            match kind {
                b"IHDR" => ihdr = body.to_vec(),
                b"IDAT" => idat.extend_from_slice(body),
                b"IEND" => break,
                _ => panic!("unexpected chunk"),
            }
            p += 12 + n;
        }
        assert_eq!(p + 12, png.len(), "nothing after IEND");
        let w = u32::from_be_bytes(ihdr[0..4].try_into().unwrap());
        let h = u32::from_be_bytes(ihdr[4..8].try_into().unwrap());
        assert_eq!(ihdr[8], 8);
        assert_eq!((idat[0], idat[1]), (0x78, 0x01));
        assert_eq!(
            ((idat[0] as u16) << 8 | idat[1] as u16) % 31,
            0,
            "a valid zlib header"
        );
        let raw = inflate(&idat[2..idat.len() - 4]);
        assert_eq!(adler32(&raw).to_be_bytes(), idat[idat.len() - 4..]);
        let stride = w as usize * 3;
        assert_eq!(raw.len(), (stride + 1) * h as usize);
        let mut px = vec![];
        for r in raw.chunks_exact(stride + 1) {
            assert_eq!(r[0], 0, "filter none");
            px.extend_from_slice(&r[1..]);
        }
        (w, h, ihdr[9], px)
    }

    fn inflate(d: &[u8]) -> Vec<u8> {
        let mut pos = 0usize;
        let mut bit = |n: u32| -> u32 {
            let mut v = 0;
            for k in 0..n {
                v |= ((d[pos / 8] >> (pos % 8)) as u32 & 1) << k;
                pos += 1;
            }
            v
        };
        let mut out: Vec<u8> = vec![];
        loop {
            let last = bit(1);
            assert_eq!(bit(2), 1, "only fixed-code blocks are written");
            loop {
                let mut code = 0;
                let mut len = 0;
                let sym = loop {
                    code = code << 1 | bit(1);
                    len += 1;
                    match (len, code) {
                        (7, 0..=0x17) => break code + 256,
                        (8, 0x30..=0xbf) => break code - 0x30,
                        (8, 0xc0..=0xc7) => break code - 0xc0 + 280,
                        (9, 0x190..=0x1ff) => break code - 0x190 + 144,
                        (9, _) => panic!("not a fixed code"),
                        _ => {}
                    }
                };
                match sym {
                    0..=255 => out.push(sym as u8),
                    256 => break,
                    _ => {
                        let s = (sym - 257) as usize;
                        let n = LEN_BASE[s] as usize + bit(LEN_EXTRA[s] as u32) as usize;
                        let mut c = 0;
                        for _ in 0..5 {
                            c = c << 1 | bit(1);
                        }
                        let dist = DIST_BASE[c as usize] as usize
                            + bit(DIST_EXTRA[c as usize] as u32) as usize;
                        assert!(
                            dist <= out.len() && dist <= WINDOW,
                            "a distance inside the window"
                        );
                        for _ in 0..n {
                            out.push(out[out.len() - dist]);
                        }
                    }
                }
            }
            if last == 1 {
                return out;
            }
        }
    }

    fn noise(n: usize, seed: u32) -> Vec<u8> {
        let mut x = seed;
        (0..n)
            .map(|_| {
                x = x.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                (x >> 24) as u8
            })
            .collect()
    }

    #[test]
    fn the_checksums_match_the_standard_vectors() {
        assert_eq!(crc32(b"123456789"), 0xcbf4_3926);
        assert_eq!(crc32(b""), 0);
        assert_eq!(adler32(b"Wikipedia"), 0x11e6_0398);
        assert_eq!(adler32(&vec![0xff; 100_000]), {
            let (mut a, mut b) = (1u64, 0u64);
            for _ in 0..100_000 {
                a = (a + 255) % 65521;
                b = (b + a) % 65521;
            }
            ((b << 16) | a) as u32
        });
        // A real PNG's IHDR chunk CRC, from a 1x1 RGB file made by libpng.
        assert_eq!(
            crc32(b"IHDR\0\0\0\x01\0\0\0\x01\x08\x02\0\0\0"),
            0x9077_53de
        );
    }

    #[test]
    fn every_kind_of_picture_comes_back_pixel_for_pixel() {
        let flat: Vec<u8> = [30u8, 30, 46].repeat(640 * 400);
        let gradient: Vec<u8> = (0..300 * 200)
            .flat_map(|i| [(i % 300) as u8, (i / 300) as u8, 128])
            .collect();
        let mut text = flat.clone(); // a flat window with a few rows of noise, like lines of text
        for r in [10usize, 11, 12, 200, 201] {
            text[r * 640 * 3..(r + 1) * 640 * 3].copy_from_slice(&noise(640 * 3, r as u32));
        }
        let cases: Vec<(u32, u32, Vec<u8>)> = vec![
            (1, 1, vec![1, 2, 3]),
            (2, 2, vec![9; 12]),
            (640, 400, flat),
            (300, 200, gradient),
            (640, 400, text),
            (97, 61, noise(97 * 61 * 3, 7)),
            // One row is wider than deflate's window, so the row above is out of reach.
            (
                11_000,
                3,
                [
                    noise(11_000 * 3, 1),
                    noise(11_000 * 3, 1),
                    noise(11_000 * 3, 2),
                ]
                .concat(),
            ),
        ];
        for (w, h, px) in cases {
            let png = encode_rgb(w, h, &px).unwrap();
            assert_eq!(crate::shot::png_size(&png), Some((w, h)));
            let (dw, dh, colour, back) = decode(&png);
            assert_eq!((dw, dh, colour), (w, h, 2), "{w}x{h}");
            assert!(back == px, "{w}x{h}: the pixels differ");
        }
    }

    #[test]
    fn a_flat_window_is_small() {
        let png = encode_rgb(1878, 1038, &[30u8, 30, 46].repeat(1878 * 1038)).unwrap();
        assert!(
            png.len() < 120_000,
            "{} bytes for 5.8 MB of one colour",
            png.len()
        );
    }

    #[test]
    fn sizes_that_do_not_agree_are_refused() {
        assert!(encode_rgb(2, 2, &[0; 11]).is_none());
        assert!(encode_rgb(0, 2, &[]).is_none());
        assert!(encode_rgb(2, 0, &[]).is_none());
    }
}
