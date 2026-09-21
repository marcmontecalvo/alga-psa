import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import type { Knex } from 'knex';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const currentDir = path.dirname(fileURLToPath(import.meta.url));

export type ProductCode = 'psa' | 'algadesk';

/** Run the same product bootstrap seeds used by hosted Temporal provisioning. */
export async function runTenantOnboardingSeeds(
  db: Knex,
  tenantId: string,
  productCode: ProductCode
): Promise<string[]> {
  const seedDir = path.resolve(currentDir, '../../../ee/server/seeds/onboarding', productCode);
  if (!fs.existsSync(seedDir)) {
    throw new Error(`Onboarding seed directory is missing: ${seedDir}`);
  }

  const seedFiles = fs.readdirSync(seedDir)
    .filter((file) => file.endsWith('.cjs'))
    .sort((left, right) => left.localeCompare(right, undefined, { sensitivity: 'base' }));
  if (seedFiles.length === 0) {
    throw new Error(`No onboarding seeds found for product ${productCode}`);
  }

  await db.transaction(async (trx) => {
    await trx.raw(`SELECT set_config('app.current_tenant', ?, true)`, [tenantId]);
    for (const seedFile of seedFiles) {
      const seedModule = require(path.join(seedDir, seedFile)) as {
        seed?: (connection: Knex.Transaction, scopedTenantId: string) => Promise<void>;
      };
      if (typeof seedModule.seed !== 'function') {
        throw new Error(`Onboarding seed does not export seed(): ${seedFile}`);
      }
      await seedModule.seed(trx, tenantId);
    }
  });

  return seedFiles;
}
