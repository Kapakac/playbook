# Стек

- Bash и make: `init.sh`, `scripts/sync-rules.sh`, цели в `Makefile`. Зависимостей, кроме git и стандартных утилит, нет.
- Проверки: shellcheck (`make lint`), тесты скриптов `tests/run.sh` (`make test`), совпадение блока в `AGENTS.md` с `rules.md` (`make check-rules`).
- GitHub Actions: `.github/workflows/ci.yml` запускает все три проверки.
