FROM python:3.12.10-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

RUN groupadd --gid 10001 livescale \
    && useradd --uid 10001 --gid 10001 --no-create-home livescale

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY livescale ./livescale

USER 10001:10001
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2)"]

CMD ["uvicorn", "livescale.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
