import asyncio
import logging
import os
import sys
import time

from core.config import load_config
from core.engine import MigrationEngine
from api.routes import create_app


def setup_logging(level: str):
    logging.basicConfig(
        level=getattr(logging, level.upper(), logging.INFO),
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
        handlers=[logging.StreamHandler(sys.stdout)],
    )


async def main():
    config = load_config()
    setup_logging(config.get("log_level", "INFO"))

    logger = logging.getLogger("torrentbridge")
    logger.info("=" * 50)
    logger.info("  TorrentBridge starting up")
    logger.info("=" * 50)

    engine = MigrationEngine(config)
    engine._start_time = time.time()
    await engine.start()

    from aiohttp import web
    app = create_app(engine, config)
    port = config.get("web_port", 7474)

    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "0.0.0.0", port)
    await site.start()

    logger.info(f"Web UI available at http://0.0.0.0:{port}")
    logger.info(f"Polling qBit-A every {config.get('poll_interval', 30)}s")

    try:
        await asyncio.Event().wait()  # run forever
    except (KeyboardInterrupt, SystemExit):
        logger.info("Shutting down...")
        await engine.stop()
        await runner.cleanup()


if __name__ == "__main__":
    asyncio.run(main())
