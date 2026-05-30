FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

WORKDIR /app

COPY agent/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY agent ./agent

EXPOSE 8989

CMD ["uvicorn", "agent.main:app", "--host", "0.0.0.0", "--port", "8989"]
