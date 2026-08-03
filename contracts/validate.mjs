#!/usr/bin/env node
/**
 * Valida os contratos contra as ESPECIFICAÇÕES OFICIAIS.
 *
 * POR QUE ISTO EXISTE
 *
 * O enunciado pede "contratos em formato padrão AsyncAPI ou OpenAPI 3.0" e
 * "exemplos funcionais de contratos". Até a primeira revisão de ciclo, a
 * verificação existente checava apenas que o YAML parseava e que os `$ref`
 * apontavam para arquivos existentes — o que não é a mesma coisa que ser um
 * documento AsyncAPI válido.
 *
 * E não era. O parser oficial falhava nos dois eventos, porque os `$ref`
 * entre schemas eram URIs absolutas para um domínio que não resolve: o
 * dereferenciador tentava buscar pela rede. Qualquer pessoa que abrisse o
 * contrato no AsyncAPI Studio ou num gerador veria erro.
 *
 * A lição: "o arquivo parseia" e "a ferramenta padrão aceita" são afirmações
 * diferentes, e só a segunda é a que o enunciado pede.
 *
 *   npm --prefix contracts run validate
 */

import { Parser, fromFile } from "@asyncapi/parser";
import SwaggerParser from "@apidevtools/swagger-parser";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CONTRACTS = HERE;

let failed = false;

// --- AsyncAPI ---------------------------------------------------------
const { document, diagnostics } = await fromFile(
  new Parser(),
  path.join(CONTRACTS, "asyncapi.yaml")
).parse();

const errors = diagnostics.filter((d) => d.severity === 0);
const warnings = diagnostics.filter((d) => d.severity === 1);

if (document && errors.length === 0) {
  const channels = document.channels().all().length;
  const operations = document.operations().all().length;
  console.log(
    `asyncapi: válido — ${channels} canais, ${operations} operações, ${warnings.length} aviso(s)`
  );
  warnings.slice(0, 5).forEach((d) =>
    console.log(`  aviso  ${(d.path || []).join("/")}: ${d.message}`)
  );
} else {
  failed = true;
  console.error(`asyncapi: INVÁLIDO — ${errors.length} erro(s)`);
  errors.slice(0, 10).forEach((d) =>
    console.error(`  ${(d.path || []).join("/")}: ${d.message}`)
  );
}

// --- OpenAPI ----------------------------------------------------------
try {
  const api = await SwaggerParser.validate(path.join(CONTRACTS, "openapi.yaml"));
  const paths = Object.keys(api.paths || {}).length;
  console.log(`openapi:  válido — ${api.openapi}, ${paths} caminho(s)`);
} catch (e) {
  failed = true;
  console.error("openapi:  INVÁLIDO");
  String(e.message)
    .split("\n")
    .slice(0, 8)
    .forEach((l) => console.error(`  ${l}`));
}

process.exit(failed ? 1 : 0);
