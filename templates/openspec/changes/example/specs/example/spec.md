# Delta: <область>

<!-- Дельта для openspec/specs/<область>/spec.md. Лишние разделы удали. Служебные слова (заголовки, GIVEN/WHEN/THEN, SHALL/MUST) — по-английски, текст — по-русски. -->

## Purpose

<!-- Только для новой области: одна-две фразы, зачем она. Для существующей удали раздел. -->

## ADDED Requirements

### Requirement: <название>

Система SHALL <одно наблюдаемое поведение>.

#### Scenario: <какой случай>

- **GIVEN** <исходное состояние>
- **WHEN** <действие>
- **THEN** <результат>
- **AND** <ещё результат>

#### Scenario: <ошибка или граница>

- **GIVEN** <исходное состояние>
- **WHEN** <действие>
- **THEN** <результат>

## MODIFIED Requirements

### Requirement: <название, как в openspec/specs/>

Система MUST <новое поведение целиком>.
(Было: <что было>)

#### Scenario: <какой случай>

- **GIVEN** <исходное состояние>
- **WHEN** <действие>
- **THEN** <результат>

## REMOVED Requirements

### Requirement: <название, как в openspec/specs/>

(Почему убираем: <причина>)

## RENAMED Requirements

- FROM: `### Requirement: <старое название>`
- TO: `### Requirement: <новое название>`
