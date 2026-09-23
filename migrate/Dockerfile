# One-shot: applies shelf's Prisma migrations from the release tag pinned in docker-compose.yml.
FROM node:22.23.2-slim

WORKDIR /database
# Prisma's query engine needs libssl, which the slim image leaves out.
RUN apt-get update && apt-get install -y --no-install-recommends openssl && rm -rf /var/lib/apt/lists/*
# prisma.config.ts loads dotenv, so it is installed next to the pinned Prisma CLI.
RUN npm install --no-save --no-audit --no-fund prisma@6.19.3 dotenv@17.4.1
COPY --from=shelf-database prisma ./prisma
COPY --from=shelf-database prisma.config.ts ./prisma.config.ts

ENTRYPOINT ["npx", "--no-install", "prisma", "migrate", "deploy"]
