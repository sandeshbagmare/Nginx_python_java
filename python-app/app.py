"""
Python layer of the reproduction: FastAPI on Uvicorn, SSE via Starlette streaming.

This layer is CORRECT and is NOT the source of the bug. We never set
`Transfer-Encoding` ourselves. For an HTTP/1.1 response with no `Content-Length`,
Uvicorn's protocol layer frames the body as chunked and emits EXACTLY ONE
`Transfer-Encoding: chunked`. (Verified for both the `httptools` and `h11`
Uvicorn HTTP backends -- see ../evidence/1-uvicorn-direct.txt.)

Run (from repo root):
    ./.venv/Scripts/python.exe -m uvicorn app:app --app-dir python-app --host 127.0.0.1 --port 8000
"""
import asyncio

from fastapi import FastAPI
from fastapi.responses import StreamingResponse, JSONResponse
from sse_starlette.sse import EventSourceResponse

app = FastAPI(title="SSE duplicate Transfer-Encoding repro")


async def event_generator():
    for i in range(5):
        yield f"data: message {i}\n\n"   # SSE wire format
        await asyncio.sleep(0.15)


@app.get("/sse")
async def sse():
    # Starlette StreamingResponse -- the endpoint described in the bug report.
    # No Content-Length and NO Transfer-Encoding set here on purpose.
    return StreamingResponse(
        event_generator(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@app.get("/sse2")
async def sse2():
    # sse-starlette's EventSourceResponse -- identical framing, for completeness.
    async def gen():
        for i in range(5):
            yield {"data": f"message {i}"}
            await asyncio.sleep(0.15)

    return EventSourceResponse(gen())


@app.get("/plain")
def plain():
    # Contrast endpoint: fixed-length JSON -> Content-Length, NO Transfer-Encoding.
    # This is why non-streaming routes never hit the bug: there is no TE to copy.
    return JSONResponse({"ok": True})
