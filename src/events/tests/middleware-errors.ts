import { describe, test } from 'vitest'

import { validateJson } from '@/tests/lib/validate-json-schema'
import { formatErrors } from '../lib/middleware-errors'
import { schemas } from '../lib/schema'

describe('formatErrors', () => {
  test('should produce objects that match the validation spec', () => {
    // Produce an error
    const { errors } = validateJson({ type: 'string' }, 0)
    const formattedErrors = formatErrors(errors || [], '')
    for (const formatted of formattedErrors) {
      const { isValid, errors } = validateJson(schemas.validation, formatted)
      if (!isValid) {
        throw new Error(errors?.map((e) => e.message).join(' -- '))
      }
    }
  })
})
