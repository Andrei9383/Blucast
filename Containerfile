FROM docker.io/nvidia/cuda:11.8.0-cudnn8-devel-ubuntu20.04@sha256:28cb396884380adc15a4bda23e9654610cbc4e20a3292d7e7679a717db5f90d2 AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    cmake build-essential libopencv-dev libv4l-dev \
    && rm -rf /var/lib/apt/lists/*

COPY sdk/TensorRT-8.5.1.7 /usr/local/TensorRT-8.5.1.7
COPY sdk/VideoFX          /usr/local/VideoFX
COPY sdk/cudnn             /usr/local/cuda/

ENV LD_LIBRARY_PATH=/usr/local/TensorRT-8.5.1.7/lib:/usr/local/VideoFX/lib:/usr/local/cuda/lib64:$LD_LIBRARY_PATH

WORKDIR /build
COPY app/ /app/

RUN mkdir -p /build/blucast && cd /build/blucast && \
    cmake /app \
    -DCMAKE_CXX_FLAGS='-I/usr/local/VideoFX/include -I/usr/local/VideoFX/share/samples/utils' \
    -DCMAKE_EXE_LINKER_FLAGS='-L/usr/local/VideoFX/lib -Wl,-rpath,/usr/local/VideoFX/lib:/usr/local/TensorRT-8.5.1.7/lib' && \
    make -j$(nproc)

FROM docker.io/nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu20.04@sha256:c2336dadc71ae5b5ce490a55cc0100d876287d28f429a5d2840c8a3a8e86fef0

LABEL maintainer="BluCast"
LABEL description="AI-powered virtual camera with NVIDIA VideoFX"
LABEL org.opencontainers.image.source="https://github.com/Andrei9383/BluCast"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    libopencv-videoio4.2 libopencv-imgproc4.2 libopencv-highgui4.2 \
    python3 python3-pip v4l-utils \
    libxcb-cursor0 libxcb-xinerama0 libxcb-icccm4 libxcb-keysyms1 \
    libxcb-shape0 libegl1 libgl1-mesa-glx libxkbcommon0 libxkbcommon-x11-0 \
    libdbus-1-3 fonts-ubuntu fontconfig \
    && fc-cache -fv \
    && rm -rf /var/lib/apt/lists/*

# Pin to Python 3.8-compatible versions (Ubuntu 20.04 ships python3.8).
# PySide6 >= 6.7.0 requires Python 3.10+; numpy 2.x requires Python 3.10+.
# To add hash verification: run pip-compile --generate-hashes inside a
# python:3.8-slim container and COPY the resulting requirements.txt here.
RUN pip3 install --no-cache-dir \
    "PySide6==6.6.3.1" \
    "numpy==1.26.4"

COPY --from=builder /build/blucast/blucast_server /app/blucast_server

COPY --from=builder /usr/local/TensorRT-8.5.1.7/lib/libnvinfer.so.8*        /usr/local/lib/blucast/
COPY --from=builder /usr/local/TensorRT-8.5.1.7/lib/libnvinfer_plugin.so.8* /usr/local/lib/blucast/
COPY --from=builder /usr/local/TensorRT-8.5.1.7/lib/libnvparsers.so.8*      /usr/local/lib/blucast/
COPY --from=builder /usr/local/TensorRT-8.5.1.7/lib/libnvonnxparser.so.8*   /usr/local/lib/blucast/
COPY --from=builder /usr/local/VideoFX/lib/libVideoFX.so*     /usr/local/lib/blucast/
COPY --from=builder /usr/local/VideoFX/lib/libNVCVImage.so*   /usr/local/lib/blucast/
COPY --from=builder /usr/local/VideoFX/lib/libNVTRTLogger.so* /usr/local/lib/blucast/

COPY --from=builder /usr/local/VideoFX/lib/models /usr/local/VideoFX/lib/models

RUN ln -sf /usr/local/lib/blucast/libVideoFX.so /usr/local/lib/blucast/libNVVideoEffects.so

COPY app/control_panel.py /app/
COPY assets/              /app/assets/

ENV LD_LIBRARY_PATH=/usr/local/lib/blucast:$LD_LIBRARY_PATH
WORKDIR /app

RUN mkdir -p /tmp/blucast /root/.config/blucast

RUN echo '#!/bin/bash\n\
set -e\n\
echo "Starting BluCast server..."\n\
/app/blucast_server --model_dir=/usr/local/VideoFX/lib/models &\n\
SERVER_PID=$!\n\
\n\
# Wait for the command pipe to be created\n\
for i in $(seq 1 30); do\n\
    [ -p /tmp/blucast/cmd.pipe ] && break\n\
    sleep 0.5\n\
done\n\
\n\
echo "Starting BluCast GUI..."\n\
python3 /app/control_panel.py\n\
EXIT_CODE=$?\n\
\n\
# Cleanup: kill server\n\
kill $SERVER_PID 2>/dev/null || true\n\
wait $SERVER_PID 2>/dev/null || true\n\
exit $EXIT_CODE\n\
' > /app/start.sh && chmod +x /app/start.sh

CMD ["/app/start.sh"]
