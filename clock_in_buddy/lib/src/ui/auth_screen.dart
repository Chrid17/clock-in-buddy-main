import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/session.dart';
import 'widgets.dart';

enum _Mode { signIn, signUp, reset }

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  static const _lastEmailKey = 'last_used_email';

  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  _Mode _mode = _Mode.signIn;
  bool _busy = false;
  bool _showPassword = false;
  String? _message;
  bool _messageIsError = false;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      final last = prefs.getString(_lastEmailKey);
      if (last != null && mounted && _email.text.isEmpty) {
        setState(() => _email.text = last);
      }
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  void _switch(_Mode mode) => setState(() {
        _mode = mode;
        _message = null;
      });

  Future<void> _submit() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    final session = context.read<Session>();
    setState(() {
      _busy = true;
      _message = null;
    });
    String? result;
    switch (_mode) {
      case _Mode.signIn:
        result = await session.signIn(_email.text, _password.text);
        if (result == null) {
          try {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString(_lastEmailKey, _email.text.trim());
          } catch (_) {}
        }
      case _Mode.signUp:
        result = await session.signUp(_name.text, _email.text, _password.text);
      case _Mode.reset:
        result = await session.resetPassword(_email.text);
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = result;
      _messageIsError = result != null &&
          !(result.startsWith('Account created') || result.startsWith('If that email'));
      if (_mode == _Mode.signUp && result != null && !_messageIsError) _mode = _Mode.signIn;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final title = switch (_mode) {
      _Mode.signIn => 'Welcome back',
      _Mode.signUp => 'Create your account',
      _Mode.reset => 'Reset your password',
    };

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _form,
                child: AutofillGroup(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(22),
                            gradient: LinearGradient(
                              colors: [scheme.primary, scheme.tertiary],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                          ),
                          child: Icon(Icons.fingerprint_rounded, size: 40, color: scheme.onPrimary),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text('Clock In Buddy',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 4),
                      Text('Clock in from anywhere with photo and GPS proof',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
                      const SizedBox(height: 32),
                      Text(title, style: theme.textTheme.titleLarge),
                      const SizedBox(height: 16),
                      if (_mode == _Mode.signUp) ...[
                        TextFormField(
                          controller: _name,
                          textCapitalization: TextCapitalization.words,
                          autofillHints: const [AutofillHints.name],
                          decoration: const InputDecoration(
                            labelText: 'Full name',
                            prefixIcon: Icon(Icons.person_outline),
                            border: OutlineInputBorder(),
                          ),
                          validator: (v) =>
                              (v ?? '').trim().length < 2 ? 'Enter your full name' : null,
                        ),
                        const SizedBox(height: 12),
                      ],
                      TextFormField(
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        autofillHints: const [AutofillHints.email],
                        decoration: const InputDecoration(
                          labelText: 'Work email',
                          prefixIcon: Icon(Icons.mail_outline),
                          border: OutlineInputBorder(),
                        ),
                        validator: (v) {
                          final text = (v ?? '').trim();
                          if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(text)) {
                            return 'Enter a valid email address';
                          }
                          return null;
                        },
                      ),
                      if (_mode != _Mode.reset) ...[
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _password,
                          obscureText: !_showPassword,
                          autofillHints: [
                            _mode == _Mode.signUp ? AutofillHints.newPassword : AutofillHints.password,
                          ],
                          decoration: InputDecoration(
                            labelText: 'Password',
                            prefixIcon: const Icon(Icons.lock_outline),
                            border: const OutlineInputBorder(),
                            suffixIcon: IconButton(
                              tooltip: _showPassword ? 'Hide password' : 'Show password',
                              icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility),
                              onPressed: () => setState(() => _showPassword = !_showPassword),
                            ),
                          ),
                          onFieldSubmitted: (_) => _submit(),
                          validator: (v) {
                            final text = v ?? '';
                            if (_mode == _Mode.signUp && text.length < 8) {
                              return 'Use at least 8 characters';
                            }
                            if (text.isEmpty) return 'Enter your password';
                            return null;
                          },
                        ),
                      ],
                      if (_message != null) ...[
                        const SizedBox(height: 16),
                        InfoBanner(
                          icon: _messageIsError ? Icons.error_outline : Icons.mark_email_read_outlined,
                          message: _message!,
                          color: _messageIsError ? scheme.error : scheme.primary,
                        ),
                      ],
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: _busy ? null : _submit,
                        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                        child: _busy
                            ? const SizedBox(
                                width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                            : Text(switch (_mode) {
                                _Mode.signIn => 'Sign in',
                                _Mode.signUp => 'Create account',
                                _Mode.reset => 'Send reset link',
                              }),
                      ),
                      const SizedBox(height: 12),
                      if (_mode == _Mode.signIn) ...[
                        TextButton(
                          onPressed: () => _switch(_Mode.reset),
                          child: const Text('Forgot password?'),
                        ),
                        TextButton(
                          onPressed: () => _switch(_Mode.signUp),
                          child: const Text('New here? Create an account'),
                        ),
                      ] else
                        TextButton(
                          onPressed: () => _switch(_Mode.signIn),
                          child: const Text('Back to sign in'),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
