"""Known-text CTC alignment with official local Wav2Vec2 weights. AUDIO RECEIPT MODEL_DIRECTORY OUTPUT"""
import hashlib
import importlib.metadata as metadata
import json
from pathlib import Path
import signal
import subprocess
import sys
import time
import numpy as np
import torch
import torchaudio
from ctc_text import normalize_ctc_text

def require(condition, message):
    if not condition:
        raise RuntimeError(message)

signal.alarm(300)
torch.set_num_threads(2)
if len(sys.argv) != 5:
    raise SystemExit("usage: run_ctc_alignment.py AUDIO RECEIPT MODEL_DIRECTORY OUTPUT")
audio,receipt_path,model_dir,output=map(Path,sys.argv[1:])
checkpoint=model_dir/'wav2vec2_fairseq_base_ls960_asr_ls960.pth'
expected_hash='488fd4f16de84438ffc945334278c1b9fb9b7159a806c1080b16111a958c945d'
require(checkpoint.is_file(), 'pinned CTC checkpoint is missing')
require(hashlib.sha256(checkpoint.read_bytes()).hexdigest()==expected_hash, 'unapproved model bytes')
receipt=json.loads(receipt_path.read_text());rate=receipt['sampleRate']
raw_pcm=subprocess.check_output(['ffmpeg','-v','error','-i',str(audio),'-ac','1','-f','f32le','-'])
source=np.frombuffer(raw_pcm,dtype='<f4')
require(len(source)==receipt['finalizedFrames']==receipt['writtenFrames'], 'audio frame receipt mismatch')
started=time.monotonic();bundle=torchaudio.pipelines.WAV2VEC2_ASR_BASE_960H
model=bundle.get_model(dl_kwargs={'model_dir':str(model_dir),'progress':False})
labels=bundle.get_labels();dictionary={c:i for i,c in enumerate(labels)}
all_segments=[];evidence=[]
for utterance in receipt['utterances']:
    begin,end=utterance['startFrame'],utterance['endFrame']
    require(0<=begin<end<=len(source), 'utterance frame range is invalid')
    require(np.max(np.abs(source[begin:end]))>0.003, 'silent utterance rejected before inference')
    parts,chars,removed=normalize_ctc_text(utterance['text'],labels)
    targets=torch.tensor([[dictionary[c] for c in chars]],dtype=torch.int32)
    decoded=subprocess.check_output(['ffmpeg','-v','error','-i',str(audio),'-af',f'atrim=start_sample={begin}:end_sample={end}','-ac','1','-ar','16000','-f','f32le','-'])
    waveform=torch.from_numpy(np.frombuffer(decoded,dtype='<f4').copy()).unsqueeze(0)
    with torch.inference_mode():
        emissions,_=model(waveform)
        log_probs=emissions.log_softmax(-1)
        path,scores=torchaudio.functional.forced_align(log_probs,targets,blank=0)
    spans=torchaudio.functional.merge_tokens(path[0],scores[0].exp(),blank=0)
    require([s.token for s in spans]==targets[0].tolist(),'CTC path coverage differs from normalized transcript')
    require(all(s.start<s.end for s in spans),'zero-duration CTC token')
    frame_seconds=((end-begin)/rate)/log_probs.shape[1]
    greedy=torch.unique_consecutive(log_probs[0].argmax(-1));greedy_text=''.join(labels[i] for i in greedy.tolist() if i!=0).replace('|',' ').strip()
    word_rows=[]
    for part in parts:
        selected=spans[part['charStart']:part['charEnd']]
        a=begin/rate+selected[0].start*frame_seconds;b=begin/rate+selected[-1].end*frame_seconds
        require(begin/rate<=a<b<=end/rate, 'word timing is outside its utterance origin')
        word_rows.append({'word':' '+part['text'],'start':a,'end':b,'probability':sum(s.score*(s.end-s.start) for s in selected)/sum(s.end-s.start for s in selected),'tokens':[s.token for s in selected],'characterRange':{'location':part['location'],'length':part['length']},'utteranceId':utterance['id'],'ctcEmissionStart':selected[0].start,'ctcEmissionEnd':selected[-1].end})
    all_segments.append({'id':utterance['id'],'text':utterance['text'],'words':word_rows})
    evidence.append({'utteranceId':utterance['id'],'sourceStartFrame':begin,'sourceEndFrame':end,'sourceSampleRate':rate,'modelSampleRate':16000,'decodedInputSamples':waveform.shape[1],'emissionFrames':log_probs.shape[1],'secondsPerEmissionFrame':frame_seconds,'frameClockMethod':'Exact source utterance duration divided by emitted acoustic frame count, following torchaudio tutorial ratio; finite acoustic frame resolution applies.','normalizedTranscript':''.join(chars),'normalizationEvents':removed,'greedyCTCText':greedy_text,'ctcTokens':[{'symbol':labels[s.token],'token':s.token,'startEmissionFrame':s.start,'endEmissionFrame':s.end,'meanProbability':s.score} for s in spans]})
    np.savez_compressed(output.with_name(output.stem+'-'+utterance['id']+'-emissions.npz'),log_probs=log_probs[0].numpy(),path=path[0].numpy(),path_log_scores=scores[0].numpy(),target=targets[0].numpy())
    print(json.dumps({'event':'utterance-aligned','id':utterance['id'],'words':len(word_rows),'greedyCTCText':greedy_text}),flush=True)
output.write_text(json.dumps({'origin':'torchaudio CTC forced alignment with WAV2VEC2_ASR_BASE_960H','segments':all_segments,'acousticEvidence':evidence,'isHumanGroundTruth':False},indent=2)+'\n')
provenance={'model':'torchaudio WAV2VEC2_ASR_BASE_960H','modelSHA256':expected_hash,'modelURL':'https://download.pytorch.org/torchaudio/models/'+checkpoint.name,'modelLicense':'MIT','audioSHA256':hashlib.sha256(audio.read_bytes()).hexdigest(),'receiptSHA256':hashlib.sha256(receipt_path.read_bytes()).hexdigest(),'elapsedSeconds':time.monotonic()-started,'device':'cpu','threads':2,'packages':{p:metadata.version(p) for p in ['torch','torchaudio','numpy']},'wordCount':sum(len(s['words']) for s in all_segments),'isHumanGroundTruth':False,'sourceSampleRate':rate,'sourceFrames':len(source)}
output.with_suffix('.provenance.json').write_text(json.dumps(provenance,indent=2)+'\n')
print(json.dumps(provenance),flush=True)
