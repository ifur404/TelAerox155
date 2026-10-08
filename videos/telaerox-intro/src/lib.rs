//! Intro “Dari Jalan, Jadi Cerita”. Rute dan ringkasan adalah ilustrasi sintetis.
use fframes::{AudioMap, AudioTrack, AudioTimestamp::*, Color, Duration, FFramesContext,
    FontQuery, Frame, Scene, Scenes, Svgr, Transform, Video, animation::Easing, include_media_dir};
use std::sync::OnceLock;
include_media_dir!(pub struct TelaeroxIntroMedia, "media");
pub const WIDTH: usize = 1080;
pub const HEIGHT: usize = 1920;
const FONT: &str = "DM Sans";
const ORANGE: &str = "#FF8149";
const WHITE: &str = "#F6F1E8";
const MUTED: &str = "#ADA9A2";
const IDENTITY_AT: f32 = 4.5;

#[derive(Debug)]
struct Chapter { name: &'static str, seconds: f32 }
impl Scene for Chapter {
    fn name(&self) -> &'static str { self.name }
    fn duration(&self) -> Duration<'_> { Duration::Seconds(self.seconds) }
    fn render_frame<'a>(&'a self, _: Frame, _: &FFramesContext<'a, '_>) -> Svgr<'a> { Svgr::empty() }
}
#[derive(Debug)]
pub struct TelaeroxIntroVideo<'a> {
    pub media: &'a TelaeroxIntroMedia,
    title: String,
    title_size: OnceLock<usize>,
    route: Chapter,
    analysis: Chapter,
    identity: Chapter,
    route_points: Vec<(f32, f32)>,
    graph_points: Vec<(f32, f32)>,
}
fn interpolate(points: &[(f32,f32)], t: f32) -> (f32,f32) {
    let f = t.clamp(0., 1.) * (points.len()-1) as f32;
    let i = (f as usize).min(points.len()-2);
    let k = f - i as f32;
    (points[i].0+(points[i+1].0-points[i].0)*k, points[i].1+(points[i+1].1-points[i].1)*k)
}
impl<'a> TelaeroxIntroVideo<'a> {
    pub fn new(media: &'a TelaeroxIntroMedia, title: &str) -> Self {
        let route = [(220.,1180.),(330.,1070.),(305.,945.),(485.,825.),(610.,900.),(710.,790.),(845.,730.)];
        let graph = [(180.,1060.),(290.,1010.),(405.,1030.),(520.,920.),(640.,960.),(760.,870.),(900.,895.)];
        Self { media, title: title.to_string(), title_size: OnceLock::new(),
            route: Chapter { name: "Rute", seconds: 2.5 },
            analysis: Chapter { name: "Ringkasan", seconds: 2.0 },
            identity: Chapter { name: "Identitas", seconds: 3.5 },
            route_points: (0..97).map(|i|interpolate(&route,i as f32/96.)).collect(),
            graph_points: (0..97).map(|i|interpolate(&graph,i as f32/96.)).collect() }
    }
}
impl Video for TelaeroxIntroVideo<'_> {
    const FPS: usize = 30;
    const WIDTH: usize = WIDTH;
    const HEIGHT: usize = HEIGHT;
    const BACKGROUND_COLOR: Color = Color::BLACK;
    fn duration(&self) -> Duration<'_> { Duration::Auto }
    fn define_scenes(&self) -> Scenes<'_> { Scenes::from(vec![&self.route as &dyn Scene, &self.analysis, &self.identity]) }
    fn audio(&self) -> AudioMap<'_> {
        AudioMap::from([AudioTrack::new("intro.wav", Second(0.)..Eof).gain_db(-2.0).fade_out(0.35)])
    }
    fn render_frame<'a>(&'a self, mut frame: Frame, ctx: &FFramesContext<'a, '_>) -> Svgr<'a> {
        let t = frame.seconds();
        let ease = Easing::CubicBezier(0.16, 1.0, 0.3, 1.0);
        let draw = frame.animate(&fframes::timeline!(at 0.15 => 1.7, animate 0.015_f32 => 1.0, Easing::EaseInOut));
        let morph = frame.animate(&fframes::timeline!(at 1.9 => 2.6, animate 0.0_f32 => 1.0, Easing::EaseInOut));
        let out = frame.animate(&fframes::timeline!(at 4.3 => 4.65, animate 1.0_f32 => 0.0, Easing::EaseIn));
        let cards = frame.animate(&fframes::timeline!(at 2.2 => 2.7, animate 0.0_f32 => 1.0, ease));
        let reveal = frame.animate(&fframes::timeline!(at 4.35 => 4.9, animate 0.0_f32 => 1.0, ease));
        let subtitle = frame.animate(&fframes::timeline!(at IDENTITY_AT => 5.05, animate 0.0_f32 => 1.0, ease));
        let rise = frame.animate(&fframes::timeline!(at 4.35, animate 60.0_f32 => 0.0,
            Easing::Spring { mass: 1.0, stiffness: 150.0, damping: 22.0 }));
        let size = *self.title_size.get_or_init(|| {
            let mut size = 112;
            while size > 32 {
                if frame.text_width(ctx, FontQuery { family: FONT, size, weight: 500, ..Default::default() }, &self.title).unwrap_or(864) <= 864 { break; }
                size -= 2;
            }
            size
        });
        let points: Vec<_> = self.route_points.iter().zip(&self.graph_points)
            .map(|(a,b)|(a.0+(b.0-a.0)*morph,a.1+(b.1-a.1)*morph)).collect();
        let count = ((points.len()-1) as f32*draw) as usize;
        let tip = interpolate(&points,draw);
        let mut path = format!("M {} {}",points[0].0,points[0].1);
        for p in points.iter().take(count+1).skip(1) { path.push_str(&format!(" L {} {}",p.0,p.1)); }
        path.push_str(&format!(" L {} {}",tip.0,tip.1));
        let roads: Vec<_> = (0..7).map(|i| {
            let y = 730. + i as f32*88.;
            fframes::svgr!(<path d={format!("M 140 {y} L 450 {} L 930 {}",y-85.,y+20.)} fill="none" stroke="#363A37" stroke-width="2" />)
        }).collect();
        let cross_roads: Vec<_> = (0..6).map(|i| {
            let x = 160. + i as f32*145.;
            fframes::svgr!(<path d={format!("M {x} 685 L {} 975 L {} 1270",x+80.,x-25.)} fill="none" stroke="#363A37" stroke-width="2" />)
        }).collect();
        let axes: Vec<_> = (0..4).map(|i| fframes::svgr!(
            <line x1="180" y1={820+i*90} x2="900" y2={820+i*90} stroke="#45453F" stroke-width="1" stroke-dasharray="4 12" />
        )).collect();
        let ring = 18. + ((t*0.7)%1.)*24.;
        fframes::svgr!(
            <svg xmlns="http://www.w3.org/2000/svg" width={WIDTH} height={HEIGHT} viewBox="0 0 1080 1920">
                <defs>
                    <radialGradient id="warm"><stop offset="0" stop-color="#603620" stop-opacity="0.32" /><stop offset="1" stop-color="#101310" stop-opacity="0" /></radialGradient>
                    <clipPath id="map"><rect x="130" y="665" width="820" height="620" rx="32" /></clipPath>
                </defs>
                <rect width="1080" height="1920" fill="#101310" />
                <ellipse cx={600.+(t*0.5).sin()*55.} cy="870" rx="650" ry="820" fill="url(#warm)" />
                <g font-family={FONT} font-weight="500">
                    <text x="108" y="300" font-size="28" letter-spacing="5" fill={MUTED}>"TELAEROX155"</text>
                    <circle cx="954" cy="289" r="7" fill={ORANGE} />
                    <g opacity={out}>
                        <text x="104" y="451" font-size="96" letter-spacing="-3" fill={WHITE}>"Dari jalan,"</text>
                        <text x="104" y="562" font-size="96" letter-spacing="-3" fill={ORANGE}>"jadi cerita."</text>
                        <rect x="130" y="665" width="820" height="620" rx="32" fill="#191E1A" stroke="#353A33" stroke-width="2" />
                        <g clip-path="url(#map)">
                            <g opacity={1.-morph}>{roads}{cross_roads}</g>
                            <g opacity={morph}>{axes}</g>
                            <path d={path.clone()} fill="none" stroke={ORANGE} stroke-width="24" opacity="0.07" stroke-linejoin="round" stroke-linecap="round" />
                            <path d={path} fill="none" stroke={ORANGE} stroke-width="7" stroke-linejoin="round" stroke-linecap="round" />
                            <circle cx={points[0].0} cy={points[0].1} r="10" fill="#191E1A" stroke={ORANGE} stroke-width="3" />
                            <circle cx={tip.0} cy={tip.1} r={ring} fill="none" stroke={ORANGE} stroke-width="2" opacity={0.65*(1.-((t*0.7)%1.))} />
                            <circle cx={tip.0} cy={tip.1} r="10" fill={WHITE} />
                        </g>
                        <g opacity={1.-morph}>
                            <text x="178" y="735" font-size="28" letter-spacing="4" fill={MUTED}>"JEJAK PERJALANAN"</text>
                            <text x="880" y="1240" font-size="28" text-anchor="end" fill={MUTED}>"Rute ilustrasi"</text>
                        </g>
                        <g opacity={morph}>
                            <text x="178" y="735" font-size="28" letter-spacing="4" fill={MUTED}>"RITME PERJALANAN"</text>
                        </g>
                        <g opacity={cards} transform={Transform::translate(0, (1.-cards)*35.)}>
                            <rect x="168" y="1140" width="352" height="112" rx="16" fill="#272C25" />
                            <rect x="540" y="1140" width="372" height="112" rx="16" fill="#272C25" />
                            <text x="192" y="1180" font-size="28" fill={MUTED}>"JARAK"</text>
                            <text x="192" y="1230" font-size="42" fill={WHITE}>"12,8 km"</text>
                            <text x="564" y="1180" font-size="28" fill={MUTED}>"DURASI"</text>
                            <text x="564" y="1230" font-size="42" fill={WHITE}>"24 menit"</text>
                        </g>
                        
                        <text x="540" y="1450" font-size="28" text-anchor="middle" fill="#92998D">"Ilustrasi data perjalanan"</text>
                    </g>
                    <g opacity={reveal} transform={Transform::translate(0,rise)}>
                        <rect x="408" y="625" width="264" height="264" rx="72" fill={ORANGE} />
                        <path d="M 465 818 L 514 769 L 490 719 L 552 686 L 610 735 L 568 814" fill="none" stroke="#181E18" stroke-width="12" stroke-linecap="round" stroke-linejoin="round" />
                        <circle cx="465" cy="818" r="14" fill={ORANGE} stroke="#181E18" stroke-width="8" />
                        <circle cx="568" cy="814" r="14" fill="#181E18" />
                        <text x="540" y="1052" font-size={size} letter-spacing="-4" fill={WHITE} text-anchor="middle">{self.title.as_str()}</text>
                    </g>
                    <g opacity={subtitle} text-anchor="middle">
                        <text x="540" y="1169" font-size="50" fill={MUTED}>"Setiap perjalanan"</text>
                        <text x="540" y="1234" font-size="50" fill={WHITE}>"punya cerita."</text>
                        <line x1="460" y1="1370" x2="620" y2="1370" stroke={ORANGE} stroke-width="3" />
                    </g>
                </g>
            </svg>
        )
    }
}

pub mod story;

pub mod motor;
