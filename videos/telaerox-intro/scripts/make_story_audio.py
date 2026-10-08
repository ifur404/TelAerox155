"""Musik instrumental orisinal 30 detik: 96 BPM, Rhodes sintetis, bass, beat, dan transisi."""
from pathlib import Path
import numpy as np
import wave
SR=48000
DURATION=30
N=SR*DURATION
rng=np.random.default_rng(155)
mix=np.zeros((N,2),dtype=np.float64)
BEAT=.625

def add(start, signal, pan=0., gain=1.):
    offset=round(start*SR)
    if offset<0:
        signal=signal[-offset:];offset=0
    signal=signal[:max(0,N-offset)]
    if not len(signal):return
    mix[offset:offset+len(signal),0]+=signal*gain*np.sqrt((1-pan)/2)
    mix[offset:offset+len(signal),1]+=signal*gain*np.sqrt((1+pan)/2)

def tone(freq,dur,kind='keys'):
    t=np.arange(round(dur*SR))/SR
    attack=np.minimum(1,t/.012)
    release=np.minimum(1,(dur-t)/.15)
    if kind=='bass':
        return (np.sin(2*np.pi*freq*t)+.22*np.sin(4*np.pi*freq*t))*attack*release*np.exp(-1.8*t)
    return (np.sin(2*np.pi*freq*t)+.2*np.sin(4*np.pi*freq*t)+.08*np.sin(6*np.pi*freq*t))*attack*release*np.exp(-1.5*t)

# Empat akor, berpindah tiap bagian lima detik.
chords=[(146.83,174.61,220.,261.63),(116.54,146.83,174.61,220.),(130.81,164.81,196.,246.94),(110.,130.81,164.81,196.)]
for bar in range(6):
    chord=chords[bar%4]
    start=bar*5
    for j,f in enumerate(chord):
        add(start+.02*j,tone(f,4.8),pan=(j-1.5)*.25,gain=.08)
    for step in range(8):
        f=chord[[0,2,1,3,2,1,3,2][step]]*2
        start_note=start+step*BEAT
        if start_note<27.7:
            sig=tone(f,.8)
            pan=(-.4 if step%2 else .4)
            add(start_note,sig,pan=pan,gain=.075)
            add(start_note+BEAT*.75,sig,pan=-pan,gain=.02)
        if step%2==0 and start_note<27.:
            add(start_note,tone(chord[0]/2,.95,'bass'),gain=.19)

for i in range(44):
    at=i*BEAT
    # Kick lembut, rim singkat, dan hi-hat ringan.
    t=np.arange(int(.35*SR))/SR
    kick=np.sin(2*np.pi*(48*t+48*.035*(1-np.exp(-t/.035))))*np.exp(-17*t)*np.minimum(1,t/.003)
    if i%2==0:add(at,kick,gain=.3)
    if i%4 in (2,):
        t=np.arange(int(.16*SR))/SR
        snare=(rng.normal(0,1,len(t))*.4+np.sin(2*np.pi*185*t)*.25)*np.exp(-37*t)*np.minimum(1,t/.002)
        add(at,snare,pan=.12,gain=.13)
    for off in (0.,BEAT/2):
        t=np.arange(int(.065*SR))/SR
        noise=rng.normal(0,1,len(t));noise=np.diff(noise,prepend=noise[0])
        hat=noise*np.exp(-75*t)*np.minimum(1,t/.001)
        add(at+off,hat,pan=(-.35 if off==0 else .35),gain=.018 if off==0 else .011)

# Efek transisi mengikuti pergantian adegan.
for at in (4.65,9.65,14.65,19.65,24.65):
    t=np.arange(int(.65*SR))/SR
    noise=rng.normal(0,1,len(t))
    smooth=np.convolve(noise,np.ones(24)/24,mode='same')
    sig=smooth*np.sin(np.pi*t/.65)**2
    add(at-.12,sig,pan=-.15,gain=.16)
    add(at+.22,tone(880,.24),pan=.2,gain=.018)

for f in (146.83,220.,293.665,349.23):add(25.0,tone(f,4.9),gain=.09)
t=np.arange(N)/SR
fade=np.minimum(1,t/.15)*np.minimum(1,(DURATION-t)/1.4)
mix*=fade[:,None]
# Saturasi lembut menjaga transient beat tanpa clipping.
mix=np.tanh(mix*1.25)
mix*=.78/np.max(np.abs(mix))
out=Path(__file__).resolve().parents[1]/'audio-work'/'story-raw.wav'
out.parent.mkdir(exist_ok=True)
with wave.open(str(out),'wb') as w:
    w.setparams((2,2,SR,0,'NONE','not compressed'))
    w.writeframes((mix*32767).astype('<i2').tobytes())
print(out)
