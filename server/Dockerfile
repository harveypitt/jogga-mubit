FROM python:3.12-slim

RUN useradd --create-home jogga
WORKDIR /app

COPY pyproject.toml alembic.ini ./
COPY jogga ./jogga
COPY migrations ./migrations
RUN pip install --no-cache-dir .

USER jogga
EXPOSE 8000
CMD ["uvicorn", "jogga.main:app", "--host", "0.0.0.0", "--port", "8000", \
     "--proxy-headers", "--forwarded-allow-ips", "*"]
