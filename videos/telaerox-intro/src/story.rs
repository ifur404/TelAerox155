//! Versi cerita 30 detik. Data visual dibuat sintetis dan tidak memakai lokasi pengguna.
use fframes::{AudioMap, AudioTrack, AudioTimestamp::*, Color, Duration, FFramesContext,
    Frame, Scene, Scenes, Svgr, Transform, Video, Overlap};
use crate::{TelaeroxIntroMedia, WIDTH, HEIGHT};
const FONT: &str = "DM Sans";
const ORANGE: &str = "#FF8149";
const WHITE: &str = "#F6F1E8";
const MUTED: &str = "#B1B2A8";
const PANEL: &str = "#1B211B";
fn progress(t:f32,a:f32,b:f32)->f32 { ((t-a)/(b-a)).clamp(0.,1.) }
fn ease(t:f32,a:f32,b:f32)->f32 { 1.-(1.-progress(t,a,b)).powi(3) }
fn route(p:f32)->(String,f32,f32) {
    let pts=[(228.,1194.),(342.,1080.),(313.,946.),(494.,827.),(618.,902.),(708.,782.),(847.,726.)];
    let f=p.clamp(0.,1.)*6.; let i=(f as usize).min(5);let k=f-i as f32;
    let (x,y)=(pts[i].0+(pts[i+1].0-pts[i].0)*k,pts[i].1+(pts[i+1].1-pts[i].1)*k);
    let mut d=String::from("M 228 1194");
    for point in pts.iter().take(i+1).skip(1) {d.push_str(&format!(" L {} {}",point.0,point.1));}
    d.push_str(&format!(" L {x} {y}"));(d,x,y)
}
fn map<'a>(p:f32, replay:bool)->Svgr<'a> {
    let (d,x,y)=route(p);
    let roads:Vec<_>=(0..8).map(|i| {
        let yy=680+i*83;
        fframes::svgr!(<path d={format!("M 130 {yy} L 466 {} L 950 {}",yy-62,yy+28)} fill="none" stroke="#394138" stroke-width="2" />)
    }).collect();
    let cross:Vec<_>=(0..6).map(|i| {
        let xx=180+i*140;
        fframes::svgr!(<path d={format!("M {xx} 665 L {} 930 L {} 1285",xx+75,xx-28)} fill="none" stroke="#394138" stroke-width="2" />)
    }).collect();
    fframes::svgr!(<g>
        <defs><clipPath id={if replay {"replaymap"}else{"routemap"}}><rect x="130" y="665" width="820" height="620" rx="32" /></clipPath></defs>
        <rect x="130" y="665" width="820" height="620" rx="32" fill={PANEL} stroke="#394238" stroke-width="2" />
        <g clip-path={if replay {"url(#replaymap)"}else{"url(#routemap)"}}>{roads}{cross}</g>
        <path d={route(1.).0} fill="none" stroke="#735340" stroke-width="5" stroke-linecap="round" stroke-linejoin="round" />
        <path d={d.clone()} fill="none" stroke={ORANGE} stroke-width="24" opacity="0.08" stroke-linecap="round" stroke-linejoin="round" />
        <path d={d} fill="none" stroke={ORANGE} stroke-width="7" stroke-linecap="round" stroke-linejoin="round" />
        <circle cx="228" cy="1194" r="10" fill={PANEL} stroke={ORANGE} stroke-width="3" />
        <circle cx={x} cy={y} r="26" fill={ORANGE} opacity="0.15" />
        <circle cx={x} cy={y} r="9" fill={WHITE} />
    </g>)
}
#[derive(Debug)]
struct StoryScene { index:usize }
impl Scene for StoryScene {
    fn name(&self)->&'static str { ["Pembuka","Rekam","Rute","Grafik","Ringkasan","Penutup"][self.index] }
    fn duration(&self)->Duration<'_> { Duration::Seconds(5.) }
    fn overlap(&self)->Overlap { if self.index==0 {Overlap::Previous(0.)}else{Overlap::Previous(0.35)} }
    fn render_frame<'a>(&'a self, frame:Frame, _: &FFramesContext<'a,'_>)->Svgr<'a> {
        let t=frame.seconds();
        let len=if self.index==0 {5.}else{5.35};
        let opacity=if self.index==0 {1.}else{ease(t,0.,0.35)} * if self.index==5 {1.}else{1.-progress(t,len-0.35,len)};
        let dy=(1.-ease(t,0.,0.65))*38.;
        let (h1,h2)=match self.index {0=>("TelAerox155","Kenali motor lo."),1=>("Rekam setiap","perjalanan."),2=>("Lihat lagi","jejak lo."),3=>("Baca ritme","perjalanan."),4=>("Satu perjalanan.","Banyak cerita."),_=>("","")};
        let main=match self.index {
            0 => {
                let pulse=0.6+0.4*(t*2.).sin().abs();
                fframes::svgr!(<g>
                    <rect x="130" y="665" width="820" height="620" rx="32" fill={PANEL} stroke="#394238" stroke-width="2" />
                    <circle cx="183" cy="724" r="7" fill={ORANGE} opacity={pulse} />
                    <text x="208" y="735" font-size="28" letter-spacing="3" fill={MUTED}>"TELEMETRI MOTOR"</text>
                    <text x="540" y="948" text-anchor="middle" font-size="180" fill={WHITE}>"32"</text>
                    <text x="540" y="1010" text-anchor="middle" font-size="32" fill={ORANGE}>"km/jam"</text>
                    <line x1="178" y1="1065" x2="902" y2="1065" stroke="#3C453A" stroke-width="2" />
                    <text x="180" y="1136" font-size="28" letter-spacing="3" fill={MUTED}>"PUTARAN MESIN"</text>
                    <text x="180" y="1210" font-size="54" fill={WHITE}>"4.100 rpm"</text>
                    <text x="625" y="1136" font-size="28" letter-spacing="3" fill={MUTED}>"SUHU MESIN"</text>
                    <text x="625" y="1210" font-size="54" fill={WHITE}>"84°C"</text>
                    <text x="540" y="1395" text-anchor="middle" font-size="40" fill={WHITE}>"Telemetri Aerox di iPhone."</text>
                </g>)
            },
            1 => {
                let pulse=0.6+0.4*(t*3.).sin().abs();
                let bars:Vec<_>=(0..31).map(|i| {
                    let h=14.+((i as f32*1.2-t*2.2).sin()*0.5+0.5)*64.;
                    fframes::svgr!(<rect x={206+i*22} y={970.-h/2.} width="7" height={h} rx="3" fill={ORANGE} opacity={0.3+i as f32/45.} />)
                }).collect();
                fframes::svgr!(<g>
                    <rect x="130" y="665" width="820" height="620" rx="32" fill={PANEL} stroke="#394238" stroke-width="2" />
                    <circle cx="192" cy="735" r="9" fill={ORANGE} opacity={pulse} />
                    <text x="220" y="746" font-size="30" letter-spacing="3" fill={ORANGE}>"MEREKAM PERJALANAN"</text>
                    <text x="540" y="887" font-size="100" text-anchor="middle" fill={WHITE}>{format!("00:{:02}",12+t.floor() as usize)}</text>
                    {bars}
                    <line x1="178" y1="1045" x2="902" y2="1045" stroke="#3C453A" stroke-width="2" />
                    <text x="184" y="1120" font-size="32" fill={MUTED}>"TELEMETRI MOTOR"</text>
                    <text x="184" y="1195" font-size="42" fill={WHITE}>"Tersimpan"</text>
                    <circle cx="853" cy="1108" r="8" fill={ORANGE} />
                    <text x="578" y="1120" font-size="32" fill={MUTED}>"RUTE GPS"</text>
                    <text x="578" y="1195" font-size="42" fill={WHITE}>"Tercatat"</text>
                    <text x="540" y="1395" text-anchor="middle" font-size="40" fill={WHITE}>"Telemetri dan GPS, dalam satu rekaman."</text>
                </g>)
            },
            2 => {
                let p=ease(t,0.35,4.4);
                fframes::svgr!(<g>{map(p,true)}
                    <text x="178" y="728" font-size="28" letter-spacing="3" fill={MUTED}>"PUTAR ULANG RUTE"</text>
                    <rect x="178" y="1330" width="724" height="5" rx="2" fill="#3B4338" />
                    <rect x="178" y="1330" width={(724.*p).max(0.5)} height="5" rx="2" fill={ORANGE} />
                    <circle cx={178.+724.*p} cy="1332" r="10" fill={WHITE} />
                    <text x="178" y="1390" font-size="30" fill={MUTED}>"MULAI"</text>
                    <text x="902" y="1390" font-size="30" text-anchor="end" fill={MUTED}>"TIBA"</text>
                </g>)
            },
            3 => {
                let p=ease(t,0.3,2.7);
                let n=(p*60.).floor() as usize;
                let mut d=String::from("M 184 1150");
                for i in 0..=n {let x=184.+i as f32*11.8;let y=1120.-i as f32*3.1-55.*(i as f32*0.18).sin()-20.*(i as f32*0.43).sin();d.push_str(&format!(" L {x} {y}"));}
                let axes:Vec<_>=(0..4).map(|i|fframes::svgr!(<line x1="180" y1={880+i*85} x2="902" y2={880+i*85} stroke="#3D453A" stroke-width="1" stroke-dasharray="4 10" />)).collect();
                fframes::svgr!(<g>
                    <rect x="130" y="665" width="820" height="620" rx="32" fill={PANEL} stroke="#394238" stroke-width="2" />
                    <text x="178" y="739" font-size="28" letter-spacing="3" fill={MUTED}>"KECEPATAN SEPANJANG RUTE"</text>
                    <text x="178" y="813" font-size="38" fill={WHITE}>"Setiap perubahan, terlihat."</text>
                    {axes}
                    <path d={d.clone()} fill="none" stroke={ORANGE} stroke-width="24" opacity="0.07" stroke-linecap="round" />
                    <path d={d} fill="none" stroke={ORANGE} stroke-width="6" stroke-linecap="round" stroke-linejoin="round" />
                    <text x="182" y="1239" font-size="28" fill={MUTED}>"AWAL"</text><text x="900" y="1239" text-anchor="end" font-size="28" fill={MUTED}>"AKHIR"</text>
                    <text x="540" y="1395" text-anchor="middle" font-size="40" fill={WHITE}>"Lihat grafik dari rekaman lo."</text>
                </g>)
            },
            4 => {
                let cards:Vec<_>=[("JARAK","12,8","km"),("DURASI","24","menit"),("RATA-RATA","32","km/jam")].iter().enumerate().map(|(i,(label,value,unit))| {
                    let a=ease(t,0.12+i as f32*0.12,0.72+i as f32*0.12);let y=665+i*197;
                    fframes::svgr!(<g opacity={a} transform={Transform::translate(0,(1.-a)*35.)}>
                        <rect x="130" y={y} width="820" height="175" rx="28" fill={PANEL} stroke="#394238" stroke-width="2" />
                        <text x="174" y={y+60} font-size="28" letter-spacing="3" fill={MUTED}>{*label}</text>
                        <text x="174" y={y+132} font-size="62" fill={WHITE}>{*value}</text>
                        <text x="902" y={y+130} text-anchor="end" font-size="36" fill={ORANGE}>{*unit}</text>
                    </g>)
                }).collect();
                fframes::svgr!(<g>{cards}<text x="540" y="1375" text-anchor="middle" font-size="40" fill={WHITE}>"Cerita perjalanan, dalam angka."</text></g>)
            },
            _ => fframes::svgr!(<g>
                <rect x="408" y="625" width="264" height="264" rx="72" fill={ORANGE} />
                <path d="M 465 818 L 514 769 L 490 719 L 552 686 L 610 735 L 568 814" fill="none" stroke="#181E18" stroke-width="12" stroke-linecap="round" stroke-linejoin="round" />
                <circle cx="465" cy="818" r="14" fill={ORANGE} stroke="#181E18" stroke-width="8" /><circle cx="568" cy="814" r="14" fill="#181E18" />
                <text x="540" y="1052" text-anchor="middle" font-size="112" letter-spacing="-4" fill={WHITE}>"TelAerox155"</text>
                <g opacity={ease(t,0.25,0.8)}>
                    <text x="540" y="1170" text-anchor="middle" font-size="50" fill={MUTED}>"Setiap perjalanan"</text>
                    <text x="540" y="1235" text-anchor="middle" font-size="50" fill={WHITE}>"punya cerita."</text>
                    <line x1="460" y1="1370" x2="620" y2="1370" stroke={ORANGE} stroke-width="3" />
                </g>
            </g>),
        };
        fframes::svgr!(<g opacity={opacity} transform={Transform::translate(0,dy)} font-family={FONT} font-weight="500">
            <text x="104" y="451" font-size={if self.index==4 || self.index==0 {84}else{96}} letter-spacing="-3" fill={WHITE}>{h1}</text>
            <text x="104" y="562" font-size={if self.index==4 || self.index==0 {84}else{96}} letter-spacing="-3" fill={ORANGE}>{h2}</text>
            {main}
            <text x="540" y="1470" text-anchor="middle" font-size="28" fill="#92998D" opacity={if self.index==5 {0.}else{1.}}>"Ilustrasi tampilan dan data"</text>
        </g>)
    }
}
#[derive(Debug)]
pub struct StoryVideo<'a> { pub media:&'a TelaeroxIntroMedia, chapters:[StoryScene;6] }
impl<'a> StoryVideo<'a> {pub fn new(media:&'a TelaeroxIntroMedia)->Self {Self{media,chapters:std::array::from_fn(|index|StoryScene{index})}}}
impl Video for StoryVideo<'_> {
    const FPS:usize=30;const WIDTH:usize=WIDTH;const HEIGHT:usize=HEIGHT;const BACKGROUND_COLOR:Color=Color::BLACK;
    fn duration(&self)->Duration<'_> {Duration::Auto}
    fn define_scenes(&self)->Scenes<'_> {Scenes::from(self.chapters.iter().map(|s|s as &dyn Scene).collect::<Vec<_>>())}
    fn audio(&self)->AudioMap<'_> {AudioMap::from([AudioTrack::new("story-music.wav",Second(0.)..Eof).gain_db(-0.6).fade_out(1.2)])}
    fn render_frame<'a>(&'a self, frame:Frame,ctx:&FFramesContext<'a,'_>)->Svgr<'a> {
        let t=frame.seconds();
        let steps:Vec<_>=(0..6).map(|i|fframes::svgr!(<g>
            <rect x={108+i*148} y="1550" width="124" height="3" rx="1" fill="#3C4339" />
            <rect x={108+i*148} y="1550" width={(124.*progress(t,i as f32*5.,i as f32*5.+5.)).max(0.5)} height="3" rx="1" fill={ORANGE} />
        </g>)).collect();
        fframes::svgr!(<svg xmlns="http://www.w3.org/2000/svg" width={WIDTH} height={HEIGHT} viewBox="0 0 1080 1920">
            <defs><radialGradient id="storywarm"><stop offset="0" stop-color="#603620" stop-opacity="0.3" /><stop offset="1" stop-color="#101310" stop-opacity="0" /></radialGradient></defs>
            <rect width="1080" height="1920" fill="#101310" />
            <ellipse cx={590.+(t*0.4).sin()*60.} cy="870" rx="600" ry="780" fill="url(#storywarm)" />
            <text x="108" y="300" font-family={FONT} font-weight="500" font-size="28" letter-spacing="5" fill={MUTED}>"TELAEROX155"</text>
            <circle cx="954" cy="289" r="7" fill={ORANGE} />
            {ctx.render_scenes(&frame)}
            {steps}
        </svg>)
    }
}
