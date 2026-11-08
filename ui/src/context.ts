import { ref, watch } from 'vue'
import type { EvaluationContext, FlagConfig } from './api'

// The context last used for a dry run, shared by the flag page and "Try a context", and kept for the tab's life.
const storageKey = 'whatfeature.context'

function stored(): EvaluationContext {
  try {
    return JSON.parse(sessionStorage.getItem(storageKey) ?? '') as EvaluationContext
  } catch {
    return { targetingKey: 'june' }
  }
}

export const sharedContext = ref<EvaluationContext>(stored())
watch(sharedContext, (context) => sessionStorage.setItem(storageKey, JSON.stringify(context)), { deep: true })

/** Attribute names worth suggesting: the ones rules already use. */
export function attributesIn(configs: FlagConfig[]): string[] {
  const names = new Set<string>(['targetingKey'])
  for (const config of configs) for (const rule of config.rules) for (const condition of rule.conditions) names.add(condition.attribute)
  return [...names].sort()
}
