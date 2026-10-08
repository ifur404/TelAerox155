"""Sound bed sintetis orisinal; atmosfer udara, beat ringan, dan akor penutup."""
import math, random, struct, wave
from pathlib import Path
random.seed(155)
rate = 48000
samples = []
noise = 0.
for n in range(rate * 8):
    t = n / rate
    edge = min(1.,t/.12) * min(1.,(8-t)/.8)
    noise = .985*noise + .015*random.uniform(-1,1)
    v = .24*noise*edge
    for f in (146.832,220.,293.665,329.628):
        v += .045*math.sin(2*math.pi*f*t)*edge*(.7+.3*math.sin(t*.8))
    for at in (.15,.75,1.35,1.95,2.55,3.15,3.75,4.35,4.95,5.55,6.15,6.75):
        u=t-at
        if 0 <= u < .32:
            v += .16*math.sin(2*math.pi*(65*u-25*u*u))*math.exp(-14*u)*min(1.,u/.005)
            v += .03*random.uniform(-1,1)*math.exp(-65*u)*min(1.,u/.003)
    for at in (.15, .75, 1.35, 1.95, 2.55, 3.15):
        u=t-at
        if 0 <= u < .6:
            f = (440.,523.25,659.25)[int(at/.6)%3]
            v += .05*math.sin(2*math.pi*f*u)*math.exp(-6*u)*min(1.,u/.008)
    for at in (1.9, 4.3):
        u=t-at
        if 0<=u<.6:
            v += .7*noise*math.sin(math.pi*u/.6)**2
    u=t-4.5
    if u>=0:
        env=min(1.,u/.02)*math.exp(-.7*u)*min(1.,(8-t)/.8)
        for f in (293.665,440.,587.33,659.255):
            v += .06*env*math.sin(2*math.pi*f*u)
    samples.append(v)
peak=max(abs(v) for v in samples)
out=Path(__file__).resolve().parents[1]/'audio-work'/'intro-raw.wav'
out.parent.mkdir(exist_ok=True)
with wave.open(str(out),'wb') as w:
    w.setparams((1,2,rate,0,'NONE','not compressed'))
    w.writeframes(b''.join(struct.pack('<h',round(v/peak*.7*32767)) for v in samples))
print(out)
