# Writing Safety Exemptions

Learn when and how to mark intentional safety violations with exemption comments.

## Overview

Some code patterns detected by SafetyAuditor are intentional and safe in specific contexts. Rather than disabling the check entirely, you can mark individual occurrences with exemption comments.

## When to Use Exemptions

Use exemptions only when you can prove the pattern is safe:

1. **Lifecycle guarantees**: The value is guaranteed non-nil or the object is guaranteed alive
2. **Type guarantees**: The type is guaranteed by external contracts (Interface Builder, Codable)
3. **Intentional crashes**: The crash is preferable to continuing with invalid state

## Comment Format

The default exemption pattern is `// SAFETY:` followed by a justification:

```swift
protocol ApplicationDelegate: AnyObject {}
final class AppDelegate: ApplicationDelegate {}
let sharedDelegate: ApplicationDelegate = AppDelegate()
let json: [String: Any] = ["id": "8B0A-11"]

// SAFETY: AppDelegate is guaranteed to exist for app lifetime
let app = sharedDelegate as! AppDelegate

// SAFETY: JSON schema validates this field is always present
let id = json["id"] as! String
```

## Placement

Exemption comments can appear in two locations:

### Same Line

```swift
let optional: String? = "assigned during init"

let value = optional! // SAFETY: Set in init, never nil
```

### Previous Line

```swift
// SAFETY: URL is a compile-time constant
let url = URL(string: "https://example.com")!
```

## Custom Patterns

Configure additional exemption patterns in `.quality-gate.yml`:

```yaml
safety_exemptions:
  - "// SAFETY:"
  - "// UNSAFE:"
  - "// swiftlint:disable force_cast"
```

This allows migration from other tools' exemption formats.

## Best Practices

### Do

- Explain *why* the pattern is safe, not just *what* it does
- Keep exemptions close to the code they exempt
- Review exemptions during code review

### Don't

- Use exemptions to avoid fixing real issues
- Apply exemptions to large blocks of code
- Copy exemption comments without understanding them

## Examples

### Good Exemptions

```swift
class ViewController {}
final class MainViewController: ViewController {}
final class ParentController {}
final class Storyboard {
    func instantiateViewController(withIdentifier identifier: String) -> ViewController {
        identifier == "Main" ? MainViewController() : ViewController()
    }
}
let storyboard = Storyboard()

// SAFETY: Storyboard instantiation guarantees this type
let vc = storyboard.instantiateViewController(
    withIdentifier: "Main"
) as! MainViewController

// SAFETY: Regex is a compile-time constant, parse cannot fail
let regex = try! Regex("[a-z]+")

final class ChildController {
    // SAFETY: Parent holds strong reference, child lifetime is bounded
    unowned var delegate: ParentController // SAFETY: Parent outlives child

    init(delegate: ParentController) {
        self.delegate = delegate
    }
}
```

### Bad Exemptions

```swift
func loadConfig() -> [String: String]? { ["timeout": "30"] }

// SAFETY: This works
let badValue = optional!  // No explanation

// SAFETY: Crash if nil (this just restates the behavior)
let config = loadConfig()!
```
