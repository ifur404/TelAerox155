//! Pengenalan analisis motor menggunakan capture komponen SwiftUI asli dan data demo.
use fframes::{AudioMap, AudioTrack, AudioTimestamp::*, Color, Duration, FFramesContext,
    Frame, Scene, Scenes, Svgr, Transform, Video, Overlap};
use crate::{WIDTH, HEIGHT};
const FONT: &str = "DM Sans";
const ACCENT: &str = "#FF8149";
const WHITE: &str = "#F6F3EE";
const MUTED: &str = "#AAB2C0";
const DURATIONS: [f32;7] = [3.,5.,5.,5.,4.,5.,3.];
fn progress(t:f32,a:f32,b:f32)->f32 {((t-a)/(b-a)).clamp(0.,1.)}
fn ease(t:f32,a:f32,b:f32)->f32 {let p=progress(t,a,b);p*p*(3.-2.*p)}

// Viewport bergerak seperti menggulir panel aplikasi; gambar tidak digambar ulang sebagai mockup.
fn panel<'a>(ctx:&FFramesContext<'a,'_>,file:&str,id:&str,y:f32,h:f32,offset:f32)->Svgr<'a> {
    let Some(img)=ctx.get_image(file) else {return Svgr::empty()};
    let scale=864./img.metadata.width as f32;
    let ih=img.metadata.height as f32*scale;
    let dy=offset.clamp(0.,(ih-h).max(0.));
    fframes::svgr!(<g>
        <defs><clipPath id={id.to_string()}><rect x="108" y={y} width="864" height={h} rx="24" /></clipPath></defs>
        <g clip-path={format!("url(#{id})")}>
            <rect x="108" y={y} width="864" height={h} fill="#0E131C" />
            <image href={img.href()} x="108" y={y-dy} width="864" height={ih} />
        </g>
        <rect x="108" y={y} width="864" height={h} rx="24" fill="none" stroke="#2B3649" stroke-width="2" />
    </g>)
}
#[derive(Debug)]
struct MotorScene {index:usize}
impl Scene for MotorScene {
    fn name(&self)->&'static str {["Kenali","Kondisi","Grafik","CVT","Peta","Replay","Penutup"][self.index]}
    fn duration(&self)->Duration<'_> {Duration::Seconds(DURATIONS[self.index])}
    fn overlap(&self)->Overlap {Overlap::Previous(if self.index==0 {0.}else{0.35})}
    fn render_frame<'a>(&'a self,frame:Frame,ctx:&FFramesContext<'a,'_>)->Svgr<'a> {
        let t=frame.seconds();
        let duration=DURATIONS[self.index]+if self.index==0 {0.}else{0.35};
        let enter=if self.index==0 {1.}else{ease(t,0.,0.3)};
        let exit=if self.index==6 {1.}else{1.-ease(t,duration-0.3,duration)};
        let (one,two,caption)=match self.index {
            0=>("Kenali Aerox lo","lewat datanya.",""),
            1=>("Seberapa panas","mesin lo tadi?","Cek suhu mesin dan tegangan aki."),
            2=>("Buka gas.","Lihat responsnya.","Bandingkan RPM dengan kecepatan."),
            3=>("Baca pola CVT","dari perjalanan lo.","Lihat RPM di tiap kecepatan."),
            4=>("Telusuri lagi","rute lo.","Berwarna sesuai kecepatan."),
            5=>("Putar ulang","perjalanan lo.","Lihat posisi dan data motornya."),
            _=>("","",""),
        };
        let content=match self.index {
            0=>panel(ctx,"motor-cvt.png","intro-cvt",685.,710.,0.),
            1=>panel(ctx,"motor-kondisi.png","condition",590.,805.,320.*ease(t,1.2,3.6)),
            2=>panel(ctx,"motor-grafik.png","riding",590.,805.,520.*ease(t,1.2,3.6)),
            3=>panel(ctx,"motor-cvt.png","cvt",630.,770.,0.),
            4|5=>{
                // 8x waktu data, sama dengan opsi replay bawaan aplikasi.
                let index=if self.index==4 {0}else{(progress(t,0.25,5.25)*40.).floor() as usize};
                let name=format!("motor-map-{index:02}.png");
                let Some(img)=ctx.get_image(&name) else {return Svgr::empty()};
                let iw=img.metadata.width as f32;
                let ih=img.metadata.height as f32;
                let scale=(864./iw).min(850./ih);
                let w=iw*scale;let h=ih*scale;let x=(1080.-w)/2.;
                fframes::svgr!(<g>
                    <image href={img.href()} x={x} y="580" width={w} height={h} />
                    <rect x={x} y="580" width={w} height={h} rx="20" fill="none" stroke="#2B3649" stroke-width="2" />
                </g>)
            },
            _=>fframes::svgr!(<g>
                <text x="104" y="735" font-size="110" letter-spacing="-4" fill={WHITE}>"Habis riding,"</text>
                <text x="104" y="875" font-size="110" letter-spacing="-4" fill={ACCENT}>"buka datanya."</text>
                <line x1="108" y1="1030" x2="972" y2="1030" stroke="#364156" stroke-width="2" />
                <text x="104" y="1152" font-size="98" letter-spacing="-3" fill={WHITE}>"TelAerox155"</text>
            </g>),
        };
        fframes::svgr!(<g opacity={enter*exit} transform={Transform::translate(0,(1.-enter)*28.)} font-family={FONT} font-weight="500">
            <text x="104" y="411" font-size="92" letter-spacing="-3" fill={WHITE}>{one}</text>
            <text x="104" y="520" font-size={if self.index==3 {86}else{92}} letter-spacing="-3" fill={ACCENT}>{two}</text>
            {content}
            <text x="540" y="1465" font-size="36" text-anchor="middle" fill={WHITE}>{caption}</text>
        </g>)
    }
}
#[derive(Debug)]
pub struct MotorVideo {scenes:[MotorScene;7]}
impl MotorVideo {pub fn new()->Self {Self{scenes:std::array::from_fn(|index|MotorScene{index})}}}
impl Video for MotorVideo {
    const FPS:usize=30;const WIDTH:usize=WIDTH;const HEIGHT:usize=HEIGHT;
    const BACKGROUND_COLOR:Color=Color::BLACK;
    fn duration(&self)->Duration<'_> {Duration::Auto}
    fn define_scenes(&self)->Scenes<'_> {Scenes::from(self.scenes.iter().map(|s|s as &dyn Scene).collect::<Vec<_>>())}
    fn audio(&self)->AudioMap<'_> {AudioMap::from([AudioTrack::new("motor-music.wav",Second(0.)..Eof).gain_db(-0.6).fade_out(0.8)])}
    fn render_frame<'a>(&'a self,frame:Frame,ctx:&FFramesContext<'a,'_>)->Svgr<'a> {
        let t=frame.seconds();
        fframes::svgr!(<svg xmlns="http://www.w3.org/2000/svg" width={WIDTH} height={HEIGHT} viewBox="0 0 1080 1920">
            <rect width="1080" height="1920" fill="#080E18" />
            <path d="M 108 239 H 972" fill="none" stroke="#2D394C" stroke-width="2" />
            <text x="108" y="291" font-family={FONT} font-size="28" font-weight="500" letter-spacing="3" fill={MUTED}>"TELAEROX155 / ANALISIS MOTOR"</text>
            {ctx.render_scenes(&frame)}
            <text x="972" y="1550" text-anchor="end" font-family={FONT} font-size="28" font-weight="500" fill={MUTED} opacity={1.-ease(t,26.67,27.)}>"Data ilustrasi"</text>
        </svg>)
    }
}
