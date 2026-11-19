//! Screenshot sizes and the coordinate round trip.
//!
//! The model sees a scaled picture and answers in that picture's pixels. Every screenshot keeps its own mapping
//! (`Shot`) so a click is converted with the scale of the picture the model actually looked at, never with a
//! newer one. Mapping a screenshot pixel back lands on the centre of its footprint on the real desktop, so the
//! round trip full → screenshot → full stays inside the same screenshot pixel at every scale.

/// Anthropic's image limits for one picture: long edge and total pixels.
pub const MAX_EDGE: u32 = 2576;
pub const MAX_PIXELS: u64 = 3_750_000;
/// Default picture size (fits WXGA; a 1920x1080 desktop becomes 1280x720).
pub const DEFAULT_MAX: (u32, u32) = (1280, 800);

/// The size a `w`×`h` desktop (or region) is sent at inside a `max_w`×`max_h` box, keeping its aspect ratio,
/// never enlarged, and within Anthropic's limits whatever box was asked for.
pub fn fit(w: u32, h: u32, max_w: u32, max_h: u32) -> (u32, u32) {
    if w == 0 || h == 0 {
        return (0, 0);
    }
    let max_w = max_w.clamp(1, MAX_EDGE) as f64;
    let max_h = max_h.clamp(1, MAX_EDGE) as f64;
    let (wf, hf) = (w as f64, h as f64);
    let mut scale = (max_w / wf).min(max_h / hf).min(1.0);
    let area = wf * hf * scale * scale;
    if area > MAX_PIXELS as f64 {
        scale *= (MAX_PIXELS as f64 / area).sqrt();
    }
    let mut sw = ((wf * scale).floor() as u32).max(1);
    let mut sh = ((hf * scale).floor() as u32).max(1);
    // Floating point can leave one pixel over a limit.
    while (sw as u64) * (sh as u64) > MAX_PIXELS || sw > MAX_EDGE || sh > MAX_EDGE {
        sw = sw.saturating_sub(1).max(1);
        sh = ((sw as f64) * hf / wf).floor().max(1.0) as u32;
    }
    (sw, sh)
}

/// One picture the model saw: which part of the desktop it shows and at what size.
#[derive(Clone, Debug, PartialEq)]
pub struct Shot {
    pub id: u32,
    pub machine: String,
    /// Full desktop size at capture time.
    pub screen: (u32, u32),
    /// Top-left of the part shown (0,0 unless zoomed) and its size, in desktop pixels.
    pub origin: (u32, u32),
    pub region: (u32, u32),
    /// Picture size as sent.
    pub sent: (u32, u32),
    pub zoom: bool,
}

impl Shot {
    /// A screenshot pixel (fractions allowed) → the desktop pixel at the centre of its footprint.
    pub fn to_full(&self, x: f64, y: f64) -> Result<(i32, i32), String> {
        if !x.is_finite() || !y.is_finite() {
            return Err("Coordinates must be numbers.".into());
        }
        let (sw, sh) = self.sent;
        if x < 0.0 || y < 0.0 || x >= sw as f64 || y >= sh as f64 {
            return Err(format!(
                "({x}, {y}) is outside screenshot {} ({sw}x{sh}); use coordinates from 0 to {} and 0 to {}.",
                self.id, sw - 1, sh - 1
            ));
        }
        Ok((axis(x, self.origin.0, self.region.0, sw), axis(y, self.origin.1, self.region.1, sh)))
    }

    /// A rectangle in this picture's pixels → the desktop pixels it covers, [x, y, w, h] (for zooming in).
    pub fn rect_to_full(&self, x: f64, y: f64, w: f64, h: f64) -> Result<[u32; 4], String> {
        if ![x, y, w, h].iter().all(|v| v.is_finite()) || w < 1.0 || h < 1.0 {
            return Err("The zoom must be [x, y, width, height] with a width and height of at least 1.".into());
        }
        let (sw, sh) = (self.sent.0 as f64, self.sent.1 as f64);
        if x < 0.0 || y < 0.0 || x >= sw || y >= sh {
            return Err(format!("The zoom starts outside screenshot {} ({}x{}).", self.id, self.sent.0, self.sent.1));
        }
        let (x1, y1) = ((x + w).min(sw), (y + h).min(sh));
        let rx = self.region.0 as f64 / sw;
        let ry = self.region.1 as f64 / sh;
        let fx0 = (x * rx).floor() as u32;
        let fy0 = (y * ry).floor() as u32;
        let fx1 = ((x1 * rx).ceil() as u32).min(self.region.0).max(fx0 + 1);
        let fy1 = ((y1 * ry).ceil() as u32).min(self.region.1).max(fy0 + 1);
        Ok([self.origin.0 + fx0, self.origin.1 + fy0, fx1 - fx0, fy1 - fy0])
    }

    /// A desktop pixel → the screenshot pixel that shows it (None when outside a zoomed region).
    pub fn to_shot(&self, fx: i64, fy: i64) -> Option<(u32, u32)> {
        let rx = fx - self.origin.0 as i64;
        let ry = fy - self.origin.1 as i64;
        if rx < 0 || ry < 0 || rx >= self.region.0 as i64 || ry >= self.region.1 as i64 {
            return None;
        }
        Some((
            ((rx as u64 * self.sent.0 as u64) / self.region.0 as u64) as u32,
            ((ry as u64 * self.sent.1 as u64) / self.region.1 as u64) as u32,
        ))
    }

    /// A desktop rectangle → [x, y, w, h] in this picture (clipped; None when not visible).
    pub fn rect_to_shot(&self, r: [i64; 4]) -> Option<[u32; 4]> {
        let x0 = r[0].max(self.origin.0 as i64);
        let y0 = r[1].max(self.origin.1 as i64);
        let x1 = (r[0] + r[2]).min((self.origin.0 + self.region.0) as i64);
        let y1 = (r[1] + r[3]).min((self.origin.1 + self.region.1) as i64);
        if x1 <= x0 || y1 <= y0 {
            return None;
        }
        let (a, b) = self.to_shot(x0, y0)?;
        let (c, d) = self.to_shot(x1 - 1, y1 - 1)?;
        Some([a, b, c - a + 1, d - b + 1])
    }
}

fn axis(v: f64, origin: u32, region: u32, sent: u32) -> i32 {
    let (p, r, s) = (v.floor() as u64, region as u64, sent as u64);
    // Centre of the footprint, (p + 0.5) * r / s, kept inside the desktop pixels that p shows: from
    // ceil(p * r / s) to ceil((p + 1) * r / s) - 1 (at least one, since pictures are never enlarged).
    let centre = ((2 * p + 1) * r) / (2 * s);
    let first = (p * r).div_ceil(s);
    let last = ((p + 1) * r).div_ceil(s).saturating_sub(1).max(first);
    (origin as u64 + centre.clamp(first, last).min(r - 1)) as i32
}

#[cfg(test)]
mod tests {
    use super::*;

    fn shot(screen: (u32, u32), origin: (u32, u32), region: (u32, u32), sent: (u32, u32)) -> Shot {
        Shot { id: 1, machine: "m".into(), screen, origin, region, sent, zoom: origin != (0, 0) || region != screen }
    }

    #[test]
    fn fit_respects_limits_and_aspect() {
        assert_eq!(fit(1920, 1080, 1280, 800), (1280, 720));
        assert_eq!(fit(1280, 720, 1280, 800), (1280, 720));
        assert_eq!(fit(800, 600, 1280, 800), (800, 600)); // never enlarged
        assert_eq!(fit(2560, 1600, 1280, 800), (1280, 800));
        for &(w, h) in &[(3840u32, 2160u32), (7680, 4320), (5120, 1440), (1080, 1920), (2560, 1600), (100, 9000)] {
            let (sw, sh) = fit(w, h, 99999, 99999);
            assert!(sw <= MAX_EDGE && sh <= MAX_EDGE, "{w}x{h} -> {sw}x{sh}");
            assert!((sw as u64) * (sh as u64) <= MAX_PIXELS, "{w}x{h} -> {sw}x{sh}");
            // Same aspect ratio, give or take the rounding of one side.
            assert!((sw as f64 - w as f64 * sh as f64 / h as f64).abs() <= 1.0 || (sh as f64 - h as f64 * sw as f64 / w as f64).abs() <= 1.0, "{w}x{h} -> {sw}x{sh}");
        }
        assert_eq!(fit(0, 10, 100, 100), (0, 0));
    }

    /// Every desktop pixel → screenshot pixel → desktop pixel stays inside the same screenshot pixel.
    #[test]
    fn round_trip_every_pixel_at_several_scales() {
        let screens = [(1920u32, 1080u32), (2560, 1440), (1366, 768), (3840, 2160), (1280, 720)];
        let boxes = [(1280u32, 800u32), (1024, 768), (640, 400), (2576, 2576), (333, 222)];
        for &screen in &screens {
            for &(mw, mh) in &boxes {
                let sent = fit(screen.0, screen.1, mw, mh);
                let s = shot(screen, (0, 0), screen, sent);
                check_all(&s);
            }
        }
    }

    #[test]
    fn round_trip_in_zoomed_regions() {
        let screen = (1920, 1080);
        for &(origin, region) in &[((100u32, 50u32), (400u32, 300u32)), ((1500, 900), (420, 180)), ((0, 0), (1920, 1080)), ((7, 3), (1913, 1077))] {
            for &(mw, mh) in &[(1280u32, 800u32), (2576, 2576), (200, 200)] {
                let sent = fit(region.0, region.1, mw, mh);
                check_all(&shot(screen, origin, region, sent));
            }
        }
    }

    fn check_all(s: &Shot) {
        let max_err = (s.region.0 as f64 / s.sent.0 as f64).ceil() as i64;
        for fy in (s.origin.1..s.origin.1 + s.region.1).step_by(7) {
            for fx in s.origin.0..s.origin.0 + s.region.0 {
                let (sx, sy) = s.to_shot(fx as i64, fy as i64).unwrap();
                assert!(sx < s.sent.0 && sy < s.sent.1);
                let (bx, by) = s.to_full(sx as f64, sy as f64).unwrap();
                assert_eq!(s.to_shot(bx as i64, by as i64), Some((sx, sy)), "{s:?} {fx},{fy}");
                assert!((bx as i64 - fx as i64).abs() <= max_err && (by as i64 - fy as i64).abs() <= max_err);
            }
        }
    }

    #[test]
    fn identity_at_scale_one_and_bounds() {
        let s = shot((1280, 720), (0, 0), (1280, 720), (1280, 720));
        assert_eq!(s.to_full(0.0, 0.0).unwrap(), (0, 0));
        assert_eq!(s.to_full(1279.0, 719.0).unwrap(), (1279, 719));
        assert_eq!(s.to_full(640.7, 360.2).unwrap(), (640, 360));
        assert!(s.to_full(1280.0, 0.0).is_err());
        assert!(s.to_full(-1.0, 0.0).is_err());
        assert!(s.to_full(f64::NAN, 0.0).is_err());
    }

    #[test]
    fn rects_are_clipped_and_scaled() {
        let s = shot((1920, 1080), (0, 0), (1920, 1080), (1280, 720));
        assert_eq!(s.rect_to_shot([300, 150, 600, 300]), Some([200, 100, 400, 200]));
        let z = shot((1920, 1080), (100, 100), (200, 100), (200, 100));
        assert_eq!(z.rect_to_shot([0, 0, 150, 150]), Some([0, 0, 50, 50]));
        assert_eq!(z.rect_to_shot([500, 500, 10, 10]), None);
    }
}
