//! `baneyspaces theme preview --format png`: each product drawn in the theme's own colors, corners,
//! borders, shadow, density and indicator, one image per product and mode. It needs no browser
//! and no fonts, so it works on a headless Linux box, over SSH and for an agent that can read an
//! image. Text is a 5 by 7 pixel font in capitals, drawn in the real text colors, so a pair that
//! reads badly looks bad here too. Every color comes from the theme; nothing is a literal.

use super::png;
use super::Resolved;

pub(super) const WIDTH: usize = 720;
pub(super) const HEIGHT: usize = 420;

#[derive(Clone, Copy, PartialEq, Debug)]
pub(super) struct Rgb(pub f32, pub f32, pub f32);

impl Rgb {
    fn hex(s: &str) -> Rgb {
        let v = |i: usize| {
            u8::from_str_radix(s.get(i..i + 2).unwrap_or("80"), 16).unwrap_or(128) as f32 / 255.0
        };
        Rgb(v(1), v(3), v(5))
    }
    pub(super) fn bytes(self) -> [u8; 3] {
        let q = |c: f32| (c.clamp(0.0, 1.0) * 255.0).round() as u8;
        [q(self.0), q(self.1), q(self.2)]
    }
}

pub(super) struct Canvas {
    w: usize,
    h: usize,
    px: Vec<Rgb>,
}

/// The coverage of a rounded box at a point, from its signed distance: 1 inside, 0 outside, and
/// the fraction in between along the edge.
fn cover(px: f32, py: f32, x0: f32, y0: f32, x1: f32, y1: f32, r: f32) -> f32 {
    if x1 <= x0 || y1 <= y0 {
        return 0.0;
    }
    let (cx, cy) = ((x0 + x1) / 2.0, (y0 + y1) / 2.0);
    let (hx, hy) = ((x1 - x0) / 2.0, (y1 - y0) / 2.0);
    let r = r.clamp(0.0, hx.min(hy));
    let qx = (px - cx).abs() - (hx - r);
    let qy = (py - cy).abs() - (hy - r);
    let out = (qx.max(0.0).powi(2) + qy.max(0.0).powi(2)).sqrt();
    let d = out + qx.max(qy).min(0.0) - r;
    (0.5 - d).clamp(0.0, 1.0)
}

impl Canvas {
    pub(super) fn new(w: usize, h: usize, fill: Rgb) -> Canvas {
        Canvas {
            w,
            h,
            px: vec![fill; w * h],
        }
    }

    #[cfg(test)]
    pub(super) fn at(&self, x: usize, y: usize) -> Rgb {
        self.px[y * self.w + x]
    }

    fn blend(&mut self, x: usize, y: usize, c: Rgb, a: f32) {
        if a <= 0.0 {
            return;
        }
        let p = &mut self.px[y * self.w + x];
        let a = a.min(1.0);
        *p = Rgb(
            p.0 + (c.0 - p.0) * a,
            p.1 + (c.1 - p.1) * a,
            p.2 + (c.2 - p.2) * a,
        );
    }

    fn span(&self, a: f32, b: f32, n: usize) -> std::ops::Range<usize> {
        let lo = a.floor().max(0.0) as usize;
        let hi = (b.ceil().max(0.0) as usize).min(n);
        lo.min(hi)..hi
    }

    /// A filled box with corners of radius `r`, at opacity `a`.
    fn rect(&mut self, b: [f32; 4], r: f32, c: Rgb, a: f32) {
        let [x0, y0, x1, y1] = b;
        for y in self.span(y0, y1, self.h) {
            for x in self.span(x0, x1, self.w) {
                let k = cover(x as f32 + 0.5, y as f32 + 0.5, x0, y0, x1, y1, r);
                self.blend(x, y, c, k * a);
            }
        }
    }

    /// The edge of a box: `width` px inside its outline.
    fn stroke(&mut self, b: [f32; 4], r: f32, width: f32, c: Rgb) {
        let [x0, y0, x1, y1] = b;
        if width <= 0.0 {
            return;
        }
        let w = width;
        for y in self.span(y0, y1, self.h) {
            for x in self.span(x0, x1, self.w) {
                let (px, py) = (x as f32 + 0.5, y as f32 + 0.5);
                let outer = cover(px, py, x0, y0, x1, y1, r);
                let inner = cover(px, py, x0 + w, y0 + w, x1 - w, y1 - w, (r - w).max(0.0));
                self.blend(x, y, c, (outer - inner).max(0.0));
            }
        }
    }

    /// A soft shadow under a box: `strength` is the theme's `shadow` (0 draws nothing).
    fn shadow(&mut self, b: [f32; 4], r: f32, strength: f32, ink: Rgb) {
        let [x0, y0, x1, y1] = b;
        if strength <= 0.0 {
            return;
        }
        let steps = 8;
        for i in (1..=steps).rev() {
            let g = i as f32 * 1.6;
            self.rect(
                [x0 - g, y0 - g + 6.0, x1 + g, y1 + g + 6.0],
                r + g,
                ink,
                strength * 0.11 / (1.0 + i as f32 * 0.35),
            );
        }
    }

    fn circle(&mut self, cx: f32, cy: f32, rad: f32, c: Rgb) {
        self.rect([cx - rad, cy - rad, cx + rad, cy + rad], rad, c, 1.0);
    }

    /// Text in capitals, top left at (x, y), `scale` px per font pixel. Returns its width.
    fn text(&mut self, x: f32, y: f32, s: &str, scale: usize, c: Rgb) -> f32 {
        let mut at = x.round() as i64;
        let top = y.round() as i64;
        for ch in s.chars() {
            let g = glyph(ch.to_ascii_uppercase());
            for (row, line) in g.iter().enumerate() {
                for (col, b) in line.bytes().enumerate() {
                    if b != b'#' {
                        continue;
                    }
                    for dy in 0..scale {
                        for dx in 0..scale {
                            let px = at + (col * scale + dx) as i64;
                            let py = top + (row * scale + dy) as i64;
                            if px >= 0
                                && py >= 0
                                && (px as usize) < self.w
                                && (py as usize) < self.h
                            {
                                self.blend(px as usize, py as usize, c, 1.0);
                            }
                        }
                    }
                }
            }
            at += (6 * scale) as i64;
        }
        text_width(s, scale)
    }

    pub(super) fn rgb_bytes(&self) -> Vec<u8> {
        self.px.iter().flat_map(|p| p.bytes()).collect()
    }

    pub(super) fn png(&self) -> Vec<u8> {
        png::encode(self.w as u32, self.h as u32, &self.rgb_bytes())
    }
}

fn text_width(s: &str, scale: usize) -> f32 {
    let n = s.chars().count();
    if n == 0 {
        0.0
    } else {
        (n * 6 * scale - scale) as f32
    }
}

/// Glyph height in font pixels.
const GLYPH_H: usize = 7;

fn glyph(c: char) -> [&'static str; GLYPH_H] {
    match c {
        'A' => [
            ".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#",
        ],
        'B' => [
            "####.", "#...#", "#...#", "####.", "#...#", "#...#", "####.",
        ],
        'C' => [
            ".###.", "#...#", "#....", "#....", "#....", "#...#", ".###.",
        ],
        'D' => [
            "####.", "#...#", "#...#", "#...#", "#...#", "#...#", "####.",
        ],
        'E' => [
            "#####", "#....", "#....", "####.", "#....", "#....", "#####",
        ],
        'F' => [
            "#####", "#....", "#....", "####.", "#....", "#....", "#....",
        ],
        'G' => [
            ".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".####",
        ],
        'H' => [
            "#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#",
        ],
        'I' => [
            ".###.", "..#..", "..#..", "..#..", "..#..", "..#..", ".###.",
        ],
        'J' => [
            "..###", "...#.", "...#.", "...#.", "...#.", "#..#.", ".##..",
        ],
        'K' => [
            "#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#",
        ],
        'L' => [
            "#....", "#....", "#....", "#....", "#....", "#....", "#####",
        ],
        'M' => [
            "#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#",
        ],
        'N' => [
            "#...#", "#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#",
        ],
        'O' => [
            ".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###.",
        ],
        'P' => [
            "####.", "#...#", "#...#", "####.", "#....", "#....", "#....",
        ],
        'Q' => [
            ".###.", "#...#", "#...#", "#...#", "#.#.#", "#..#.", ".##.#",
        ],
        'R' => [
            "####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#",
        ],
        'S' => [
            ".####", "#....", "#....", ".###.", "....#", "....#", "####.",
        ],
        'T' => [
            "#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#..",
        ],
        'U' => [
            "#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###.",
        ],
        'V' => [
            "#...#", "#...#", "#...#", "#...#", "#...#", ".#.#.", "..#..",
        ],
        'W' => [
            "#...#", "#...#", "#...#", "#.#.#", "#.#.#", "#.#.#", ".#.#.",
        ],
        'X' => [
            "#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#",
        ],
        'Y' => [
            "#...#", "#...#", ".#.#.", "..#..", "..#..", "..#..", "..#..",
        ],
        'Z' => [
            "#####", "....#", "...#.", "..#..", ".#...", "#....", "#####",
        ],
        '0' => [
            ".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###.",
        ],
        '1' => [
            "..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###.",
        ],
        '2' => [
            ".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####",
        ],
        '3' => [
            "#####", "...#.", "..#..", "...#.", "....#", "#...#", ".###.",
        ],
        '4' => [
            "...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#.",
        ],
        '5' => [
            "#####", "#....", "####.", "....#", "....#", "#...#", ".###.",
        ],
        '6' => [
            "..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###.",
        ],
        '7' => [
            "#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#...",
        ],
        '8' => [
            ".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###.",
        ],
        '9' => [
            ".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##..",
        ],
        ' ' => [
            ".....", ".....", ".....", ".....", ".....", ".....", ".....",
        ],
        '.' => [
            ".....", ".....", ".....", ".....", ".....", ".##..", ".##..",
        ],
        ',' => [
            ".....", ".....", ".....", ".....", ".##..", "..#..", ".#...",
        ],
        ':' => [
            ".....", ".##..", ".##..", ".....", ".##..", ".##..", ".....",
        ],
        '-' => [
            ".....", ".....", ".....", ".###.", ".....", ".....", ".....",
        ],
        '!' => [
            "..#..", "..#..", "..#..", "..#..", "..#..", ".....", "..#..",
        ],
        '\'' => [
            "..#..", "..#..", ".#...", ".....", ".....", ".....", ".....",
        ],
        '"' => [
            ".#.#.", ".#.#.", ".....", ".....", ".....", ".....", ".....",
        ],
        '#' => [
            ".#.#.", ".#.#.", "#####", ".#.#.", "#####", ".#.#.", ".#.#.",
        ],
        '/' => [
            "....#", "...#.", "...#.", "..#..", ".#...", ".#...", "#....",
        ],
        '(' => [
            "...#.", "..#..", ".#...", ".#...", ".#...", "..#..", "...#.",
        ],
        ')' => [
            ".#...", "..#..", "...#.", "...#.", "...#.", "..#..", ".#...",
        ],
        '&' => [
            ".##..", "#..#.", "#.#..", ".#...", "#.#.#", "#..#.", ".##.#",
        ],
        '+' => [
            ".....", "..#..", "..#..", "#####", "..#..", "..#..", ".....",
        ],
        '=' => [
            ".....", ".....", "#####", ".....", "#####", ".....", ".....",
        ],
        '%' => [
            "##..#", "##..#", "...#.", "..#..", ".#...", "#..##", "#..##",
        ],
        '>' => [
            ".#...", "..#..", "...#.", "....#", "...#.", "..#..", ".#...",
        ],
        '<' => [
            "...#.", "..#..", ".#...", "#....", ".#...", "..#..", "...#.",
        ],
        '_' => [
            ".....", ".....", ".....", ".....", ".....", ".....", "#####",
        ],
        '*' => [
            ".....", "..#..", "#.#.#", ".###.", "#.#.#", "..#..", ".....",
        ],
        _ => [
            ".###.", "#...#", "....#", "...#.", "..#..", ".....", "..#..",
        ],
    }
}

/// The colors, corners and spacing one image draws with.
struct Look<'a> {
    r: &'a Resolved,
    mode: &'a str,
    /// Spacing for the theme's density.
    d: f32,
    /// Font pixel size for body text, from `type.size`.
    s: usize,
}

impl Look<'_> {
    fn c(&self, role: &str) -> Rgb {
        Rgb::hex(
            self.r
                .colors(self.mode)
                .get(role)
                .map(String::as_str)
                .unwrap_or("#808080"),
        )
    }
    fn radius(&self) -> f32 {
        self.r.shape.radius as f32
    }
    fn small(&self) -> f32 {
        self.r.shape.radius_small as f32
    }
    fn large(&self) -> f32 {
        self.r.shape.radius_large as f32
    }
    fn line(&self) -> f32 {
        self.r.shape.border_width as f32
    }
    fn shadow(&self) -> f32 {
        self.r.shape.shadow as f32
    }
    /// The darkest of the palette's colors, for a shadow that reads in light and dark.
    fn ink(&self) -> Rgb {
        let a = self.c("strong");
        let b = self.c("background");
        let lum = |c: Rgb| c.0 + c.1 + c.2;
        if lum(a) < lum(b) {
            a
        } else {
            Rgb(0.0, 0.0, 0.0)
        }
    }
    fn pad(&self, v: f32) -> f32 {
        (v * self.d).round()
    }
    fn line_h(&self) -> f32 {
        (GLYPH_H * self.s) as f32 * self.r.typ.line_height as f32
    }

    /// A card: shadow, fill, border.
    fn card(&self, cv: &mut Canvas, b: [f32; 4], r: f32, fill: &str) {
        let [x0, y0, x1, y1] = b;
        cv.shadow([x0, y0, x1, y1], r, self.shadow(), self.ink());
        cv.rect([x0, y0, x1, y1], r, self.c(fill), 1.0);
        cv.stroke([x0, y0, x1, y1], r, self.line(), self.c("border"));
    }

    /// A button with its label centered; returns its right edge.
    fn button(&self, cv: &mut Canvas, x: f32, y: f32, label: &str, fill: &str, text: &str) -> f32 {
        let s = self.s;
        let w = text_width(label, s) + self.pad(28.0);
        let h = (GLYPH_H * s) as f32 + self.pad(16.0);
        cv.rect([x, y, x + w, y + h], self.small(), self.c(fill), 1.0);
        if fill == "surface" || fill == "background" {
            cv.stroke(
                [x, y, x + w, y + h],
                self.small(),
                self.line().max(1.0),
                self.c("border"),
            );
        }
        cv.text(
            x + (w - text_width(label, s)) / 2.0,
            y + (h - (GLYPH_H * s) as f32) / 2.0,
            label,
            s,
            self.c(text),
        );
        x + w
    }
}

const STATUS: [&str; 9] = [
    "idle", "on", "working", "idle", "urgent", "idle", "done", "working", "idle",
];

fn status_role(st: &str) -> &'static str {
    match st {
        "working" => "working",
        "urgent" => "urgent",
        "done" => "done",
        "on" => "accent",
        _ => "muted",
    }
}

fn header(cv: &mut Canvas, l: &Look, title: &str, surface: &str) {
    let x = 24.0;
    let w = cv.text(x, 20.0, title, 2, l.c("strong"));
    cv.text(
        x + w + 14.0,
        20.0,
        &format!("{surface} - {} mode", l.mode),
        2,
        l.c("muted"),
    );
}

fn spaces(cv: &mut Canvas, l: &Look) {
    // The dock: nine tiles on a bar, the theme's indicator on each.
    let tile = 52.0;
    let gap = l.pad(8.0);
    let pad = l.pad(10.0);
    let bar_w = 9.0 * tile + 8.0 * gap + 2.0 * pad;
    let x0 = ((WIDTH as f32 - bar_w) / 2.0).round();
    let y0 = 58.0;
    l.card(
        cv,
        [x0, y0, x0 + bar_w, y0 + tile + 2.0 * pad],
        l.large(),
        "surface",
    );
    for (i, st) in STATUS.iter().enumerate() {
        let tx = x0 + pad + i as f32 * (tile + gap);
        let ty = y0 + pad;
        let current = *st == "on";
        cv.rect(
            [tx, ty, tx + tile, ty + tile],
            l.radius(),
            l.c(if current { "selection" } else { "sunken" }),
            1.0,
        );
        if current {
            let w = if l.line() > 0.0 {
                (l.line() * 1.5).min(8.0)
            } else {
                2.0
            };
            cv.stroke([tx, ty, tx + tile, ty + tile], l.radius(), w, l.c("accent"));
        } else {
            cv.stroke(
                [tx, ty, tx + tile, ty + tile],
                l.radius(),
                l.line(),
                l.c("border"),
            );
        }
        let n = format!("{}", i + 1);
        let s = 3;
        let nw = text_width(&n, s);
        let (nx, ny) = (tx + (tile - nw) / 2.0, ty + (tile - 21.0) / 2.0);
        let role = status_role(st);
        match l.r.shape.indicator.as_str() {
            "bar" => {
                cv.text(
                    nx,
                    ny - 3.0,
                    &n,
                    s,
                    l.c(if current { "strong" } else { "foreground" }),
                );
                cv.rect(
                    [tx + 8.0, ty + tile - 9.0, tx + tile - 8.0, ty + tile - 5.0],
                    0.0,
                    l.c(role),
                    1.0,
                );
            }
            "number-block" => {
                let (fill, ink) = match *st {
                    "on" => ("accent", "on_accent"),
                    "idle" => ("sunken", "muted"),
                    other => (status_role(other), "background"),
                };
                cv.rect(
                    [nx - 6.0, ny - 5.0, nx + nw + 6.0, ny + 26.0],
                    l.small(),
                    l.c(fill),
                    1.0,
                );
                cv.text(nx, ny, &n, s, l.c(ink));
            }
            _ => {
                cv.text(
                    nx,
                    ny,
                    &n,
                    s,
                    l.c(if current { "strong" } else { "foreground" }),
                );
                if *st != "idle" {
                    cv.circle(tx + tile - 9.0, ty + 9.0, 4.5, l.c(role));
                }
            }
        }
    }

    // The window bar: three rows, one selected, and a hint.
    let (lx0, ly0, lx1) = (24.0, 178.0, 372.0);
    let row_h = l.line_h() + l.pad(12.0);
    let ly1 = ly0 + 3.0 * row_h + 2.0 * l.pad(10.0) + l.line_h() + 8.0;
    l.card(cv, [lx0, ly0, lx1, ly1], l.radius(), "surface");
    let rows = [
        ("Mail", "Inbox, 3 new"),
        ("Code", "theme.rs"),
        ("Notes", "Groceries"),
    ];
    let mut y = ly0 + l.pad(10.0);
    for (i, (app, title)) in rows.iter().enumerate() {
        let sel = i == 1;
        if sel {
            cv.rect(
                [lx0 + 8.0, y, lx1 - 8.0, y + row_h],
                l.small(),
                l.c("selection"),
                1.0,
            );
        }
        let ty = y + (row_h - (GLYPH_H * l.s) as f32) / 2.0;
        let w = cv.text(
            lx0 + 20.0,
            ty,
            app,
            l.s,
            l.c(if sel { "strong" } else { "foreground" }),
        );
        cv.text(lx0 + 30.0 + w, ty, title, l.s, l.c("muted"));
        y += row_h;
    }
    cv.text(lx0 + 20.0, y + 8.0, "Cmd-Tab to switch", l.s, l.c("muted"));

    // A settings row with a switch that is on, and one with a choice.
    let (sx0, sy0, sx1) = (392.0, 178.0, 696.0);
    let sy1 = ly1;
    l.card(cv, [sx0, sy0, sx1, sy1], l.radius(), "surface");
    let mid = sy0 + (sy1 - sy0) / 3.0;
    cv.text(
        sx0 + 18.0,
        mid - 10.0,
        "Show the dock",
        l.s,
        l.c("foreground"),
    );
    let (kx, ky) = (sx1 - 70.0, mid - 14.0);
    cv.rect(
        [kx, ky, kx + 48.0, ky + 26.0],
        13.0_f32.min(l.large().max(4.0)),
        l.c("accent"),
        1.0,
    );
    cv.circle(kx + 35.0, ky + 13.0, 9.0, l.c("on_accent"));
    let mid2 = sy0 + 2.0 * (sy1 - sy0) / 3.0;
    cv.text(sx0 + 18.0, mid2 - 10.0, "Dock size", l.s, l.c("foreground"));
    let label = "Medium";
    let w = text_width(label, l.s) + 24.0;
    cv.rect(
        [sx1 - 22.0 - w, mid2 - 16.0, sx1 - 22.0, mid2 + 10.0],
        l.small(),
        l.c("sunken"),
        1.0,
    );
    cv.text(sx1 - 10.0 - w, mid2 - 10.0, label, l.s, l.c("foreground"));

    status_row(cv, l, 360.0);
}

fn voice(cv: &mut Canvas, l: &Look) {
    // The dictation pill.
    let (x0, y0, x1) = (60.0, 74.0, 660.0);
    let y1 = y0 + 96.0 + l.pad(12.0);
    l.card(cv, [x0, y0, x1, y1], l.large(), "surface");
    let cy = (y0 + y1) / 2.0;
    cv.circle(x0 + 52.0, cy, 26.0, l.c("accent"));
    cv.rect(
        [x0 + 46.0, cy - 13.0, x0 + 58.0, cy + 6.0],
        6.0,
        l.c("on_accent"),
        1.0,
    );
    cv.rect(
        [x0 + 51.0, cy + 6.0, x0 + 53.0, cy + 13.0],
        0.0,
        l.c("on_accent"),
        1.0,
    );
    cv.circle(x0 + 102.0, y0 + 30.0, 4.0, l.c("working"));
    cv.text(x0 + 112.0, y0 + 24.0, "Listening", l.s, l.c("working"));
    let w = cv.text(
        x0 + 96.0,
        y0 + 52.0,
        "Remind me to send the draft",
        l.s,
        l.c("foreground"),
    );
    cv.text(x0 + 106.0 + w, y0 + 52.0, "before Fri", l.s, l.c("muted"));
    for i in 0..18 {
        let hgt = [6.0, 12.0, 20.0, 9.0, 16.0, 24.0, 14.0, 7.0, 18.0][i % 9];
        let bx = x0 + 96.0 + i as f32 * 10.0;
        cv.rect(
            [bx, y1 - 18.0 - hgt, bx + 5.0, y1 - 18.0],
            2.0,
            l.c("accent"),
            1.0,
        );
    }
    let keys = "Esc cancel  Fn finish";
    cv.text(
        x1 - 20.0 - text_width(keys, l.s),
        y1 - 18.0 - (GLYPH_H * l.s) as f32,
        keys,
        l.s,
        l.c("muted"),
    );

    // Its settings.
    let (fx0, fy0, fx1, fy1) = (60.0, 210.0, 660.0, 336.0);
    l.card(cv, [fx0, fy0, fx1, fy1], l.radius(), "surface");
    cv.text(fx0 + 18.0, fy0 + 18.0, "Dictation", l.s + 1, l.c("strong"));
    cv.text(fx0 + 18.0, fy0 + 56.0, "Language", l.s, l.c("foreground"));
    cv.rect(
        [fx0 + 200.0, fy0 + 48.0, fx0 + 420.0, fy0 + 76.0],
        l.small(),
        l.c("sunken"),
        1.0,
    );
    cv.stroke(
        [fx0 + 200.0, fy0 + 48.0, fx0 + 420.0, fy0 + 76.0],
        l.small(),
        l.line(),
        l.c("border"),
    );
    cv.text(
        fx0 + 212.0,
        fy0 + 56.0,
        "English (US)",
        l.s,
        l.c("foreground"),
    );
    cv.text(
        fx0 + 18.0,
        fy0 + 92.0,
        "Words you add keep your spelling",
        l.s,
        l.c("muted"),
    );
    status_row(cv, l, 360.0);
}

fn browser(cv: &mut Canvas, l: &Look) {
    let (x0, y0, x1, y1) = (24.0, 56.0, 452.0, 400.0);
    l.card(cv, [x0, y0, x1, y1], l.radius(), "surface");
    cv.text(x0 + 16.0, y0 + 16.0, "Quarterly report", l.s, l.c("strong"));
    cv.rect(
        [x0, y0 + 44.0, x1, y0 + 44.0 + l.line().max(1.0)],
        0.0,
        l.c("border"),
        1.0,
    );
    // The person's turn, then the agent's.
    let me = "Summarize this page";
    let mw = text_width(me, l.s) + 24.0;
    cv.rect(
        [x1 - 16.0 - mw, y0 + 60.0, x1 - 16.0, y0 + 92.0],
        l.radius(),
        l.c("selection"),
        1.0,
    );
    cv.text(x1 - 4.0 - mw, y0 + 70.0, me, l.s, l.c("foreground"));
    cv.text(
        x0 + 16.0,
        y0 + 108.0,
        "It has 3 tables and one open",
        l.s,
        l.c("foreground"),
    );
    cv.text(
        x0 + 16.0,
        y0 + 108.0 + l.line_h(),
        "question about the budget.",
        l.s,
        l.c("foreground"),
    );
    cv.circle(x0 + 20.0, y0 + 144.0 + l.line_h(), 4.0, l.c("working"));
    cv.text(
        x0 + 30.0,
        y0 + 138.0 + l.line_h(),
        "Working: drafting",
        l.s,
        l.c("working"),
    );
    // The permission prompt.
    let (ay0, ay1) = (y0 + 178.0 + l.line_h(), y0 + 290.0 + l.line_h());
    cv.rect(
        [x0 + 12.0, ay0, x1 - 12.0, ay1],
        l.radius(),
        l.c("sunken"),
        1.0,
    );
    cv.stroke(
        [x0 + 12.0, ay0, x1 - 12.0, ay1],
        l.radius(),
        l.line().max(1.0),
        l.c("urgent"),
    );
    cv.text(x0 + 26.0, ay0 + 14.0, "Needs you", l.s, l.c("urgent"));
    cv.text(
        x0 + 26.0,
        ay0 + 38.0,
        "Click Send on the mail page?",
        l.s,
        l.c("foreground"),
    );
    let bx = l.button(
        cv,
        x0 + 26.0,
        ay0 + 62.0,
        "Not now",
        "surface",
        "foreground",
    );
    l.button(
        cv,
        bx + 10.0,
        ay0 + 62.0,
        "Allow once",
        "accent",
        "on_accent",
    );

    // A page beside the panel: text, a link and a field.
    let (px0, py0, px1, py1) = (472.0, 56.0, 696.0, 400.0);
    l.card(cv, [px0, py0, px1, py1], l.radius(), "background");
    cv.text(px0 + 16.0, py0 + 18.0, "Budget", l.s + 1, l.c("strong"));
    for (i, w) in [170.0, 150.0, 180.0, 120.0].iter().enumerate() {
        let y = py0 + 54.0 + i as f32 * 16.0 * l.r.typ.line_height as f32;
        cv.rect(
            [px0 + 16.0, y, px0 + 16.0 + w, y + 6.0],
            3.0,
            l.c("muted"),
            1.0,
        );
    }
    cv.text(
        px0 + 16.0,
        py0 + 150.0,
        "Open the sheet",
        l.s,
        l.c("accent"),
    );
    cv.rect(
        [
            px0 + 16.0,
            py0 + 150.0 + (GLYPH_H * l.s) as f32 + 2.0,
            px0 + 16.0 + text_width("Open the sheet", l.s),
            py0 + 152.0 + (GLYPH_H * l.s) as f32 + 2.0,
        ],
        0.0,
        l.c("accent"),
        1.0,
    );
    cv.rect(
        [px0 + 16.0, py1 - 56.0, px1 - 16.0, py1 - 20.0],
        l.small(),
        l.c("sunken"),
        1.0,
    );
    cv.stroke(
        [px0 + 16.0, py1 - 56.0, px1 - 16.0, py1 - 20.0],
        l.small(),
        l.line(),
        l.c("border"),
    );
    cv.text(px0 + 28.0, py1 - 45.0, "Ask about this", l.s, l.c("muted"));
}

fn site(cv: &mut Canvas, l: &Look) {
    let mut y = 62.0;
    cv.text(24.0, y, "One theme for every app", l.s + 1, l.c("strong"));
    y += (GLYPH_H * (l.s + 1)) as f32 + l.pad(14.0);
    for t in [
        "Your colors follow you from the dock",
        "to dictation and the browser.",
    ] {
        cv.text(24.0, y, t, l.s, l.c("foreground"));
        y += l.line_h();
    }
    y += l.pad(4.0);
    let link = "Read the guide";
    cv.text(24.0, y, link, l.s, l.c("accent"));
    let under = y + (GLYPH_H * l.s) as f32 + 2.0;
    cv.rect(
        [24.0, under, 24.0 + text_width(link, l.s), under + 2.0],
        0.0,
        l.c("accent"),
        1.0,
    );
    y += l.line_h() + l.pad(14.0);
    let bx = l.button(cv, 24.0, y, "Get Polycarp", "accent", "on_accent");
    let bx = l.button(cv, bx + 12.0, y, "Cancel", "surface", "foreground");
    l.button(cv, bx + 12.0, y, "Delete", "urgent", "background");
    // A code sample on sunken, as the site draws it.
    let (cx0, cy0, cx1, cy1) = (24.0, 246.0, 696.0, 340.0);
    cv.rect([cx0, cy0, cx1, cy1], l.radius(), l.c("sunken"), 1.0);
    cv.stroke([cx0, cy0, cx1, cy1], l.radius(), l.line(), l.c("border"));
    let lines = [
        ("# themes/mine.toml", "muted"),
        ("extends = \"polycarp\"", "foreground"),
        ("radius = 0", "strong"),
    ];
    for (i, (t, role)) in lines.iter().enumerate() {
        cv.text(
            cx0 + 18.0,
            cy0 + 16.0 + i as f32 * l.line_h(),
            t,
            l.s,
            l.c(role),
        );
    }
    status_row(cv, l, 360.0);
}

/// The three status colors as text on the page, the way every product writes them.
fn status_row(cv: &mut Canvas, l: &Look, y: f32) {
    let mut x = 24.0;
    for (label, role) in [
        ("Needs you", "urgent"),
        ("Working", "working"),
        ("Done", "done"),
    ] {
        cv.circle(x + 4.0, y + (GLYPH_H * l.s) as f32 / 2.0, 4.0, l.c(role));
        x += 14.0 + cv.text(x + 14.0, y, label, l.s, l.c(role)) + 22.0;
    }
}

/// One product in one mode.
pub(super) fn render(r: &Resolved, title: &str, surface: &str, mode: &str) -> Canvas {
    let d = match r.shape.density.as_str() {
        "compact" => 0.75,
        "spacious" => 1.3,
        _ => 1.0,
    };
    let s = ((r.typ.size as f32) / 8.0).round().clamp(1.0, 3.0) as usize;
    let l = Look { r, mode, d, s };
    let mut cv = Canvas::new(WIDTH, HEIGHT, l.c("background"));
    header(&mut cv, &l, title, surface);
    match surface {
        "voice" => voice(&mut cv, &l),
        "browser" => browser(&mut cv, &l),
        "site" => site(&mut cv, &l),
        _ => spaces(&mut cv, &l),
    }
    cv
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_glyph_is_five_by_seven() {
        for c in (32u8..127).map(char::from) {
            for row in glyph(c.to_ascii_uppercase()) {
                assert_eq!(row.len(), 5, "{c:?}");
                assert!(row.bytes().all(|b| b == b'#' || b == b'.'), "{c:?}");
            }
        }
    }

    #[test]
    fn a_round_corner_is_cut_and_a_square_one_is_not() {
        let ink = Rgb(0.0, 0.0, 0.0);
        let mut round = Canvas::new(40, 40, Rgb(1.0, 1.0, 1.0));
        round.rect([0.0, 0.0, 40.0, 40.0], 16.0, ink, 1.0);
        assert_eq!(
            round.at(0, 0),
            Rgb(1.0, 1.0, 1.0),
            "the corner shows the page"
        );
        assert_eq!(round.at(20, 20), ink);
        let mut square = Canvas::new(40, 40, Rgb(1.0, 1.0, 1.0));
        square.rect([0.0, 0.0, 40.0, 40.0], 0.0, ink, 1.0);
        assert_eq!(square.at(0, 0), ink);
    }

    fn builtin(name: &str) -> super::super::Full {
        let cfg = super::super::Cfg {
            dir: std::env::temp_dir().join("polycarp-picture-test-unused"),
            overlay: Vec::new(),
        };
        super::super::resolve_name(&cfg, name).unwrap_or_else(|e| panic!("{e:?}"))
    }

    #[test]
    fn each_image_is_drawn_in_that_theme_and_mode() {
        for name in ["polycarp", "blocks", "calm"] {
            let full = builtin(name);
            for s in ["spaces", "voice", "browser", "site"] {
                let r = full.surface(s).exported();
                for m in ["light", "dark"] {
                    let cv = render(&r, &full.title, s, m);
                    let bg = Rgb::hex(&r.colors(m)["background"]).bytes();
                    // The page is the theme's background in that mode.
                    assert_eq!(cv.at(2, 2).bytes(), bg, "{name} {s} {m}");
                    assert_eq!(cv.at(WIDTH - 3, HEIGHT - 3).bytes(), bg, "{name} {s} {m}");
                    // The accent and the text color are both on the page.
                    for role in ["accent", "foreground"] {
                        let want = Rgb::hex(&r.colors(m)[role]).bytes();
                        assert!(
                            cv.px.iter().any(|p| p.bytes() == want),
                            "{name} {s} {m}: no {role} pixel"
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn square_corners_and_the_indicator_follow_the_theme() {
        // blocks has square corners and number blocks; polycarp has round corners and dots.
        let blocks = builtin("blocks");
        let polycarp = builtin("polycarp");
        assert_eq!(blocks.base.shape.radius_large, 0);
        let sq = render(&blocks.base, "B", "spaces", "light");
        let rd = render(&polycarp.base, "P", "spaces", "light");
        // The dock's top left corner: the bar's color in a square theme, the page in a round one.
        let tile = 52.0;
        let bar_w = |d: f32| 9.0 * tile + 8.0 * (8.0 * d).round() + 2.0 * (10.0 * d).round();
        let x0 = ((WIDTH as f32 - bar_w(1.0)) / 2.0).round() as usize;
        let corner = |cv: &Canvas, l: &Resolved| {
            (
                cv.at(x0 + 2, 60).bytes(),
                Rgb::hex(&l.light["surface"]).bytes(),
            )
        };
        let (px, bar) = corner(&sq, &blocks.base);
        assert_eq!(px, bar, "a square theme's corner is the bar");
        let (px, bar) = corner(&rd, &polycarp.base);
        assert_ne!(px, bar, "a round theme's corner is cut");
    }

    #[test]
    fn a_real_preview_round_trips_through_png() {
        let full = builtin("evening");
        let cv = render(&full.base, &full.title, "browser", "dark");
        let png = cv.png();
        let (w, h, rgb) = png::tests::decode(&png);
        assert_eq!((w as usize, h as usize), (WIDTH, HEIGHT));
        assert!(rgb == cv.rgb_bytes());
        assert!(png.len() < 60_000, "{} bytes", png.len());
    }

    #[test]
    fn text_is_drawn_in_its_color() {
        let mut cv = Canvas::new(40, 12, Rgb(1.0, 1.0, 1.0));
        let red = Rgb(1.0, 0.0, 0.0);
        let w = cv.text(1.0, 1.0, "H", 1, red);
        assert_eq!(w, 5.0);
        // The left stem of H.
        assert_eq!(cv.at(1, 1), red);
        assert_eq!(cv.at(2, 1), Rgb(1.0, 1.0, 1.0));
    }
}
