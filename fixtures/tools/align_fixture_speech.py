"""Turn a local CTC alignment into one canonical T word receipt."""
import argparse
import array
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

MODEL_SHA256 = "488fd4f16de84438ffc945334278c1b9fb9b7159a806c1080b16111a958c945d"
THRESHOLD = 0.003

def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def normalized(text):
    return re.sub("[^a-z]", "", text.lower())

def text_words(receipt):
    return [word for utterance in receipt["utterances"] for word in utterance["text"].split()]

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture", required=True)
    parser.add_argument("--source", required=True, choices=("take1", "take2"))
    parser.add_argument("--python", required=True)
    parser.add_argument("--model-dir", required=True)
    args = parser.parse_args()
    fixture = Path(args.fixture)
    audio = fixture / "media" / f"{args.source}-speech.aiff"
    script = fixture / f"script-{args.source}.txt"
    receipt_path = fixture / f"audio-{args.source}.json"
    receipt = json.loads(receipt_path.read_text())
    model_dir = Path(args.model_dir)
    checkpoint = model_dir / "wav2vec2_fairseq_base_ls960_asr_ls960.pth"
    if sha256(checkpoint) != MODEL_SHA256:
        raise SystemExit("CTC model sha256 does not match the pinned Wav2Vec2 checkpoint")
    runner = Path(__file__).with_name("run_ctc_alignment.py")
    with tempfile.TemporaryDirectory() as temporary:
        raw_path = Path(temporary) / "raw.json"
        subprocess.run([args.python, runner, audio, receipt_path, model_dir, raw_path], check=True)
        raw = json.loads(raw_path.read_text())
        provenance = json.loads(raw_path.with_suffix(".provenance.json").read_text())
    raw_words = [word for segment in raw["segments"] for word in segment["words"]]
    expected = text_words(receipt)
    if [normalized(word["word"].strip()) for word in raw_words] != [normalized(word) for word in expected]:
        raise SystemExit("CTC word coverage differs from the frozen synthetic transcript")
    pcm = array.array("f")
    pcm.frombytes(subprocess.check_output(["ffmpeg", "-v", "error", "-i", str(audio), "-map", "0:a:0", "-ac", "1", "-f", "f32le", "pipe:1"]))
    rate = receipt["sampleRate"]
    frames = receipt["finalizedFrames"]
    if len(pcm) != frames or receipt["writtenFrames"] != frames:
        raise SystemExit("decoded audio frames disagree with the exact synthesis receipt")
    utterances = {utterance["id"]: utterance for utterance in receipt["utterances"]}
    words = []
    previous_end = 0.0
    for index, raw_word in enumerate(raw_words):
        start, end = raw_word["start"], raw_word["end"]
        utterance = utterances.get(raw_word["utteranceId"])
        if utterance is None:
            raise SystemExit("CTC word has an unknown utterance origin")
        minimum, maximum = utterance["startFrame"] / rate, utterance["endFrame"] / rate
        if not all(isinstance(value, (int, float)) and value == value and abs(value) != float("inf") for value in (start, end)):
            raise SystemExit("CTC word has non-finite timing")
        if not minimum <= start < end <= maximum or start < previous_end:
            raise SystemExit("CTC word timing is outside its origin or overlaps the preceding word")
        start_frame, end_frame = round(start * rate), round(end * rate)
        if not 0 <= start_frame < end_frame <= frames:
            raise SystemExit("CTC word frame range is invalid")
        next_start = round(raw_words[index + 1]["start"] * rate) if index + 1 < len(raw_words) else utterance["endFrame"]
        upper = min(utterance["endFrame"], next_start)
        active = [frame for frame in range(start_frame, upper) if abs(pcm[frame]) > THRESHOLD]
        if not active:
            raise SystemExit("CTC word has no active waveform support")
        words.append({
            "id": f"{args.source}-word-{index:03d}", "index": index, "text": raw_word["word"].strip(),
            "sourceStartSeconds": start, "sourceEndSeconds": end, "rawStartSeconds": start, "rawEndSeconds": end,
            "utteranceId": raw_word["utteranceId"], "characterRange": raw_word["characterRange"],
            "probability": raw_word["probability"], "tokens": raw_word["tokens"],
            "ctcEmissionStart": raw_word["ctcEmissionStart"], "ctcEmissionEnd": raw_word["ctcEmissionEnd"],
            "acousticTailEndFrame": active[-1] + 1, "acousticTailEndSeconds": (active[-1] + 1) / rate,
            "acousticTailMethod": "Last abs(sample)>0.003 before the next CTC onset, capped at the exact utterance end. This is an acoustic activity estimate, not a phonetic boundary."
        })
        previous_end = end
    result = {
        "origin": "torchaudio CTC known-text forced alignment", "isHumanGroundTruth": False,
        "sampleRate": rate, "durationSeconds": frames / rate, "wordCount": len(words), "words": words,
        "alignment": {"engine": "torchaudio WAV2VEC2_ASR_BASE_960H", "version": provenance["packages"]["torchaudio"], "mode": "known-text-forced", "threads": provenance["threads"], "modelSha256": provenance["modelSHA256"], "modelURL": provenance["modelURL"], "modelLicense": provenance["modelLicense"], "acousticEvidence": raw["acousticEvidence"]},
        "inputAudio": {"sha256": sha256(audio), "sampleRate": rate, "frames": frames},
        "inputText": {"sha256": sha256(script)}, "audioReceiptPath": f"audio-{args.source}.json"
    }
    (fixture / f"words-{args.source}.json").write_text(json.dumps(result, indent=2) + "\n")

if __name__ == "__main__":
    main()
