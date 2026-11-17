#!/usr/bin/env python3
"""Speed benchmark against the local LM Studio Anthropic endpoint (streaming).

Measures time-to-first-token for a prompt of ~N tokens (prefill) and decode speed.
Usage: bench.py MODEL_ID [PROMPT_TOKENS]
"""
import http.client
import json
import sys
import time

model = sys.argv[1]
target = int(sys.argv[2]) if len(sys.argv) > 2 else 8000
# ~1 token per 3.5 chars of Russian business text; varied lines defeat any prefix cache.
line = "Клиент {i}: логистическая компания, 40 сотрудников, запрос на автоматизацию документооборота. "
filler = "".join(line.format(i=i) for i in range(int(target * 3.5 / len(line)) + 1))
body = {
    "model": model,
    "max_tokens": 300,
    "stream": True,
    "messages": [{"role": "user", "content": filler + f"\n\nСколько всего клиентов перечислено? ({time.time()}) "
                  "Ответь одним числом, затем напиши 5 предложений о том, как бы ты структурировал КП."}],
}
conn = http.client.HTTPConnection("127.0.0.1", 1234, timeout=600)
t0 = time.time()
conn.request("POST", "/v1/messages", json.dumps(body),
             {"content-type": "application/json", "anthropic-version": "2023-06-01"})
resp = conn.getresponse()
first = None
usage_in = usage_out = 0
for raw in resp:
    line_s = raw.decode("utf-8", "replace").strip()
    if not line_s.startswith("data:"):
        continue
    ev = json.loads(line_s[5:])
    if ev.get("type") == "content_block_delta" and first is None:
        first = time.time()
    if ev.get("type") == "message_start":
        usage_in = ev["message"].get("usage", {}).get("input_tokens", 0)
    if ev.get("type") == "message_delta":
        usage_out = ev.get("usage", {}).get("output_tokens", usage_out)
end = time.time()
ttft = (first or end) - t0
decode = usage_out / (end - first) if first and end > first else 0
print(json.dumps({
    "model": model, "prompt_tokens": usage_in, "output_tokens": usage_out,
    "ttft_s": round(ttft, 2), "prefill_tok_s": round(usage_in / ttft, 1) if ttft else 0,
    "decode_tok_s": round(decode, 1), "total_s": round(end - t0, 2),
}, ensure_ascii=False))
