#!/usr/bin/env python3
"""
Kokoro-82M TTS Server
Local HTTP server for the SoundsRight Desktop macOS app.
Provides text-to-speech using the Kokoro-82M model.

Requirements:
    pip install kokoro flask soundfile numpy

Usage:
    python kokoro_server.py
    # Server starts on http://127.0.0.1:18923
"""

import io
import sys
import logging
from flask import Flask, request, jsonify, send_file
import numpy as np
import soundfile as sf

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)

# Available American English voices
VOICES = {
    "af_heart": "American Female - Heart (warm, default)",
    "af_bella": "American Female - Bella",
    "af_nicole": "American Female - Nicole",
    "af_sarah": "American Female - Sarah",
    "af_sky": "American Female - Sky",
    "am_adam": "American Male - Adam",
    "am_michael": "American Male - Michael",
}

DEFAULT_VOICE = "af_heart"
DEFAULT_SPEED = 1.0
MAX_TEXT_LENGTH = 1000
PORT = 18923
HOST = "127.0.0.1"

# Global pipeline instance
pipeline = None


def load_pipeline():
    """Load Kokoro pipeline on startup."""
    global pipeline
    if pipeline is not None:
        return pipeline

    try:
        logger.info("Loading Kokoro-82M pipeline...")
        from kokoro import KPipeline

        # Initialize with American English
        pipeline = KPipeline(lang_code="a")
        logger.info("Kokoro-82M pipeline loaded successfully")
        return pipeline
    except ImportError as e:
        logger.error(f"Failed to import Kokoro: {e}")
        logger.error("Install with: pip install kokoro")
        sys.exit(1)
    except Exception as e:
        logger.error(f"Failed to load Kokoro pipeline: {e}")
        sys.exit(1)


def create_app():
    """Create and configure Flask app."""
    app = Flask(__name__)

    @app.route("/health", methods=["GET"])
    def health():
        """Health check endpoint."""
        return jsonify({
            "status": "ok",
            "model": "kokoro-82m"
        }), 200

    @app.route("/voices", methods=["GET"])
    def get_voices():
        """Return available voices."""
        return jsonify(VOICES), 200

    @app.route("/tts", methods=["POST"])
    def text_to_speech():
        """Text-to-speech endpoint."""
        try:
            # Parse request JSON
            data = request.get_json()
            if data is None:
                return jsonify({"error": "Request must be JSON"}), 400

            # Validate required field
            text = data.get("text", "").strip()
            if not text:
                return jsonify({"error": "text field is required"}), 400

            if len(text) > MAX_TEXT_LENGTH:
                return jsonify({
                    "error": f"text exceeds maximum length of {MAX_TEXT_LENGTH} characters"
                }), 400

            # Optional parameters with defaults
            speed = data.get("speed", DEFAULT_SPEED)
            voice = data.get("voice", DEFAULT_VOICE)

            # Validate speed
            try:
                speed = float(speed)
                if speed < 0.3 or speed > 2.0:
                    return jsonify({
                        "error": "speed must be between 0.3 and 2.0"
                    }), 400
            except (TypeError, ValueError):
                return jsonify({"error": "speed must be a number"}), 400

            # Validate voice
            if voice not in VOICES:
                available = ", ".join(VOICES.keys())
                return jsonify({
                    "error": f"voice '{voice}' not found. Available: {available}"
                }), 400

            logger.info(f"TTS request: text={text[:50]}... voice={voice} speed={speed}")

            # Ensure pipeline is loaded
            if pipeline is None:
                return jsonify({"error": "TTS pipeline not ready"}), 500

            # Generate audio using pipeline
            try:
                audio_chunks = []
                for chunk in pipeline(text, voice=voice, speed=speed):
                    audio_chunks.append(chunk)

                if not audio_chunks:
                    return jsonify({"error": "No audio generated"}), 500

                # Concatenate audio chunks
                audio_data = np.concatenate(audio_chunks)

                # Create WAV file in memory
                wav_buffer = io.BytesIO()
                sf.write(wav_buffer, audio_data, samplerate=24000, format="WAV")
                wav_buffer.seek(0)

                logger.info(f"Audio generated successfully: {len(audio_data)} samples")

                # Return WAV file
                return send_file(
                    wav_buffer,
                    mimetype="audio/wav",
                    as_attachment=False,
                    download_name="tts.wav"
                )

            except Exception as e:
                logger.error(f"TTS synthesis failed: {e}")
                return jsonify({
                    "error": f"TTS synthesis failed: {str(e)}"
                }), 500

        except Exception as e:
            logger.error(f"Unexpected error in /tts: {e}")
            return jsonify({"error": "Internal server error"}), 500

    @app.errorhandler(404)
    def not_found(error):
        """Handle 404 errors."""
        return jsonify({"error": "Endpoint not found"}), 404

    @app.errorhandler(405)
    def method_not_allowed(error):
        """Handle 405 errors."""
        return jsonify({"error": "Method not allowed"}), 405

    return app


def main():
    """Main entry point."""
    logger.info(f"Starting Kokoro TTS Server on {HOST}:{PORT}")

    # Load pipeline on startup
    load_pipeline()

    # Create and run Flask app
    app = create_app()

    try:
        app.run(host=HOST, port=PORT, debug=False, threaded=True)
    except KeyboardInterrupt:
        logger.info("Server shutting down...")
    except Exception as e:
        logger.error(f"Server error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
