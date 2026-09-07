FROM python:3.12-alpine

RUN addgroup -S app && adduser -S -G app -u 1000 app \
  && mkdir -p /app /tmp \
  && chown -R app:app /app /tmp

WORKDIR /app
COPY main.py .

USER app
EXPOSE 8080
ENV PORT=8080
CMD ["python", "-u", "main.py"]
