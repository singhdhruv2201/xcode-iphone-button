"""Exercise request lifetime through a simulated handoff; no device/network needed."""
import asyncio
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "probe", Path(__file__).resolve().parents[1] / "tools" / "diagnose_handoff.py"
)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class RequestLifetimeTests(unittest.IsolatedAsyncioTestCase):
    async def test_transport_reset_ends_stalled_request_before_timeout(self):
        transport_closed, started, reader_closed = asyncio.Event(), asyncio.Event(), asyncio.Event()
        warnings = []
        async def stalled():
            started.set()
            try:
                await asyncio.Event().wait()
            finally:
                reader_closed.set()
        pending = asyncio.create_task(probe.wait_with_grace(
            stalled(), 10, 90, lambda: warnings.append(1), transport_closed,
        ))
        await started.wait()
        transport_closed.set()
        with self.assertRaises(probe.TunnelClosedError):
            await asyncio.wait_for(pending, 1)
        self.assertTrue(reader_closed.is_set())
        self.assertEqual(warnings, [])

    async def test_late_response_survives_warning_without_duplicate_request(self):
        released = asyncio.Event()
        warnings = []
        calls = []
        async def request():
            calls.append(1)
            await released.wait()
            return "reply"
        def warning():
            warnings.append(1)
            asyncio.get_running_loop().call_later(0.01, released.set)
        result = await probe.wait_with_grace(request(), 0.01, 1, warning)
        self.assertEqual(result, "reply")
        self.assertEqual((len(calls), len(warnings)), (1, 1))

    async def test_hard_deadline_cancels_and_joins_stalled_reader(self):
        closed = asyncio.Event()
        async def stalled():
            try:
                await asyncio.Event().wait()
            finally:
                closed.set()
        with self.assertRaises(TimeoutError):
            await probe.wait_with_grace(stalled(), 0.01, 0.03, lambda: None)
        self.assertTrue(closed.is_set())

    async def test_stop_cleans_up_pending_reader(self):
        started, closed = asyncio.Event(), asyncio.Event()
        async def stalled():
            started.set()
            try:
                await asyncio.Event().wait()
            finally:
                closed.set()
        task = asyncio.create_task(probe.wait_with_grace(stalled(), 10, 90, lambda: None))
        await started.wait()
        task.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await task
        self.assertTrue(closed.is_set())


if __name__ == "__main__":
    unittest.main()
