"""Upstream SSE app (FastAPI/Uvicorn) — the 'Python app' from the bug report.
Correct: emits exactly one Transfer-Encoding for the stream; never sets it itself.

Run:  python -m uvicorn app:app --app-dir . --host 127.0.0.1 --port 4000
"""
import asyncio
from fastapi import FastAPI
from fastapi.responses import StreamingResponse, JSONResponse


app = FastAPI(title="AI assistant SSE upstream (repro)")


async def event_generator():
    for i in range(5):
        yield f"data: message {i}\n\n"
        await asyncio.sleep(0.15)


@app.get("/sse")
async def sse():
    return StreamingResponse(
        event_generator(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@app.get("/plain")
def plain():
    return JSONResponse({"ok": True})
