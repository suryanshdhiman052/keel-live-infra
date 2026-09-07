FROM python:3.12-alpine

RUN addgroup -S shop && adduser -S -G shop -u 1000 shop \
  && mkdir -p /srv /tmp \
  && chown -R shop:shop /srv /tmp

WORKDIR /srv
COPY main.py .

USER shop
EXPOSE 8088
ENV PORT=8088
CMD ["python", "-u", "main.py"]
