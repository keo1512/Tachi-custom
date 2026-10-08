export class RuntimeError extends Error {
  constructor(code, message, status = 422) {
    super(message);
    this.code = code;
    this.status = status;
  }
}

export function capabilityError(name) {
  return new RuntimeError('UNSUPPORTED_CAPABILITY', `This runtime does not support ${name}.`, 422);
}
